defmodule MWTClient.Sandbox.ServerTest do
  use ExUnit.Case, async: true

  doctest MWTClient.Sandbox.Server.Values

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server
  alias MWTClient.Sandbox.Egress.Driver.Http1
  alias MWTClient.Vault.Store

  setup do
    MWTClient.VaultHelpers.unlocked_identity("sandbox")
  end

  @github %{
    "kind" => "token",
    "preset" => "github",
    "name" => "GitHub",
    "purpose" => "Push to oliveigah/klife",
    "hosts" => "api.github.com, github.com, uploads.github.com",
    "env" => "GITHUB_TOKEN, GH_TOKEN",
    "git" => "true",
    "prefix" => "ghp_",
    "source" => "stored"
  }

  # On, and by default letting every use through, so tests about swapping
  # don't wait; `uses: :ask` is the default for real grants.
  defp github(username, uses \\ :all) do
    {:ok, grant} =
      Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value_0123456789"))

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, uses)
    grant
  end

  defp request(grant, attrs \\ %{}) do
    Map.merge(
      %{
        host: "api.github.com",
        method: "GET",
        path: "/user",
        headers: [{"authorization", "token #{grant.placeholder}"}, {"user-agent", "gh"}],
        body: ""
      },
      attrs
    )
  end

  defp authorize(username, request),
    do: username |> Server.call({:authorize, request}) |> sent(request)

  defp authorize_async(username, request),
    do:
      Task.async(fn ->
        username |> Server.call({:authorize, request}, :infinity) |> sent(request)
      end)

  # What the request goes out with once its driver put in what the
  # verdict says (`Http1.replace/2`), and the verdict's replacements kept
  # with what to look for.
  defp sent({:forward, replace, scan}, request),
    do:
      {:forward, Http1.replace(request.headers, replace.request),
       Map.put(scan, :replace, replace)}

  defp sent(other, _request), do: other

  defp wait_for_approval(username) do
    Enum.find_value(1..100, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [approval | _] -> approval
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  test "a new identity starts empty, with a CA and a default Containerfile", %{username: username} do
    snapshot = Sandbox.snapshot(username)
    # Nothing but the Internet's grant, built in, always on, and Commands
    # agents write, on and asking.
    {mwt_tools, grants} = Enum.split_with(snapshot.grants, &(&1.kind == :mwt))

    assert [
             %{id: "internet", kind: :network, internet: true, state: :on, start: :auto},
             %{id: "agent-commands", kind: :agent_commands, state: :on, start: :on}
           ] = grants

    # MWT's own tools, built in: reading and adding always on, changing on
    # and asking; the projects' Git (fetching, fetching remotes on this
    # machine, handing off), syncing the shared folders and copying the
    # workspace's from-vm onto this machine always on.
    assert [
             %{id: "mwt-read", state: :on, start: :auto},
             %{id: "mwt-create", state: :on, start: :auto},
             %{id: "mwt-change", state: :on, start: :on},
             %{id: "git-fetch", state: :on, start: :auto},
             %{id: "git-fetch-remote", state: :on, start: :auto},
             %{id: "git-handoff", state: :on, start: :auto},
             %{id: "share-sync", state: :on, start: :auto},
             %{id: "workspace", state: :on, start: :auto}
           ] = mwt_tools

    assert Enum.map(mwt_tools, &MWTClient.Sandbox.Grant.auto_approved?/1) ==
             [true, true, false, true, true, true, true, true]

    assert snapshot.settings.image_layer == MWTClient.Sandbox.Image.default_layer()
    refute MWTClient.Sandbox.Image.whole_containerfile?(snapshot.settings.image_layer)
    assert snapshot.settings.image_name == "mwt_agent_sdb_image"
    assert snapshot.image.tag == nil
    assert snapshot.builds == []
    assert snapshot.snapshots == []
    assert Sandbox.ca_pem(username) =~ "BEGIN CERTIFICATE"
    assert File.read!(Path.join(snapshot.inbox, "ca.pem")) == Sandbox.ca_pem(username)
  end

  test "a build's output and end reach the server, which keeps running", %{username: username} do
    pid = GenServer.whereis(Store.via(Server, username))
    Phoenix.PubSub.subscribe(MWTClient.PubSub, Server.State.topic(username))

    # A layer podman refuses at once, or no podman at all: either way the
    # build prints its first line and fails fast, so the port is looked at
    # in the state that started it, before the server can hear it end.
    started =
      :sys.replace_state(pid, fn state ->
        state = put_in(state.settings.image_layer, "NOT AN INSTRUCTION\n")
        Server.Machine.start_build(state)
      end)

    assert is_port(started.build)
    assert_receive {:sandbox_build_line, "==> podman build " <> _}, 5_000

    image = built(username)
    assert image.error =~ "The build failed"
    assert :sys.get_state(pid).build == nil
  end

  test "a build is deleted unless it is current or the VM's", %{username: username} do
    pid = GenServer.whereis(Store.via(Server, username))

    builds =
      for n <- 1..3 do
        %MWTClient.Sandbox.Build{
          ref: "box:2026-11-24.#{n}",
          name: "box",
          tag: "2026-11-24.#{n}",
          built_at: DateTime.add(~U[2026-11-24 12:00:00Z], n, :minute)
        }
      end

    :sys.replace_state(pid, fn state ->
      %{
        state
        | builds: builds,
          created_ref: "box:2026-11-24.1",
          image: %{state.image | tag: "box:2026-11-24.3"}
      }
    end)

    assert {:error, :current} = Sandbox.delete_build(username, "box:2026-11-24.3")
    assert {:error, :in_use} = Sandbox.delete_build(username, "box:2026-11-24.1")
    assert {:error, :not_found} = Sandbox.delete_build(username, "box:gone")
    assert :ok = Sandbox.delete_build(username, "box:2026-11-24.2")

    assert Enum.map(Sandbox.snapshot(username).builds, & &1.ref) ==
             ["box:2026-11-24.1", "box:2026-11-24.3"]
  end

  # The image once its build ended, each change heard as it comes.
  defp built(username) do
    case Sandbox.snapshot(username).image do
      %{building?: false} = image ->
        image

      _building ->
        assert_receive {:sandbox_changed, :image}, 30_000
        built(username)
    end
  end

  test "the image name must be one OCI accepts", %{username: username} do
    assert {:error, %{image_name: _}} =
             Sandbox.update_settings(username, %{"image_name" => "My Box"})

    assert {:ok, settings} = Sandbox.update_settings(username, %{"image_name" => " my_box "})
    assert settings.image_name == "my_box"
  end

  test "only kept builds can be made current", %{username: username} do
    assert Sandbox.use_build(username, "mwt_agent_sdb_image:2026-11-12.1") == {:error, :not_found}
  end

  test "a VM created before the explicit Bash shell needs recreation", %{username: username} do
    pid = GenServer.whereis(Store.via(Server, username))

    :sys.replace_state(pid, fn state ->
      previous_spec = %{
        name: state.vm.name,
        image: "box:1",
        cpus: state.settings.cpus,
        memory_gib: state.settings.memory_gib,
        disk_gib: state.settings.disk_gib,
        mounts: :none
      }

      %{
        state
        | vm: %{state.vm | exists?: true},
          image: %{state.image | tag: "box:1"},
          created_spec: :erlang.phash2(previous_spec)
      }
    end)

    assert Sandbox.snapshot(username).vm.stale?
  end

  test "a shared folder is synced when asked while the VM runs, and what that found is shown",
       %{username: username} do
    folder = Path.join(System.tmp_dir!(), "server-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf!(folder) end)
    {:ok, _} = Sandbox.add_share(username, folder)
    pid = GenServer.whereis(Store.via(Server, username))

    # Stopped, nothing is synced: the next start will.
    send(pid, :sync)
    assert %{^folder => %{status: nil, due?: true}} = Sandbox.snapshot(username).sync

    # Running: a sync starts when asked. This test has no msb, so it says
    # so, and the pages hear it.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | vm: %{state.vm | exists?: true, status: :running},
          vm_record: %{id: "vm-test", created_at: nil, image: nil, copied: true}
      }
    end)

    Phoenix.PubSub.subscribe(MWTClient.PubSub, Server.State.topic(username))
    assert :ok = Sandbox.sync_shares(username, :all)
    assert_receive {:sandbox_changed, :sync}, 5_000
    assert %{^folder => %{status: %{error: error}}} = Sandbox.snapshot(username).sync
    assert error =~ "couldn't be shown in the VM"

    # A folder no longer shared is dropped.
    :ok = Sandbox.remove_share(username, folder)
    assert_receive {:sandbox_changed, :sync}, 5_000
    assert Sandbox.snapshot(username).sync == %{}
    refute Map.has_key?(:sys.get_state(pid).sync, folder)
  end

  test "a change to MWT's files is copied into the running VM, and agents wait for it",
       %{username: username} do
    pid = GenServer.whereis(Store.via(Server, username))

    # Stopped, nothing is copied, and nobody waits.
    {:ok, _grant} =
      Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value_0123456789"))

    assert GenServer.call(pid, :inbox_copied) == :ok
    assert :sys.get_state(pid).inbox_sync == nil

    :sys.replace_state(pid, fn state ->
      %{
        state
        | vm: %{state.vm | exists?: true, status: :running},
          vm_record: %{id: "vm-test", created_at: nil, image: nil, copied: true}
      }
    end)

    # Running: a change starts a copy, and an agent about to hear a grant is
    # on is answered once it ended. This test has no msb, so the copy says
    # what failed, and goes on from nothing next time.
    {:ok, grant} =
      Sandbox.create_grant(username, Map.merge(@github, %{"name" => "Other", "value" => "x"}))

    assert GenServer.call(pid, :inbox_copied, 10_000) == :ok

    assert %{to: "/mnt/mwt", kind: :mwt, vm: "vm-test", status: %{error: error}} =
             :sys.get_state(pid).inbox_sync

    assert error =~ "/mnt/mwt couldn't be made in the VM"
    assert %{inbox_due: false, inbox_waiters: []} = :sys.get_state(pid)

    # Turning a grant on is such a change too.
    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    assert GenServer.call(pid, :inbox_copied, 10_000) == :ok
  end

  test "a VM made with folders of this machine mounted needs recreation", %{username: username} do
    pid = GenServer.whereis(Store.via(Server, username))

    # Today's settings, as the spec recorded them while shared folders, MWT's
    # files and the memory were mounts.
    :sys.replace_state(pid, fn state ->
      spec = %{
        name: state.vm.name,
        image: "box:1",
        shell: "/bin/bash",
        cpus: state.settings.cpus,
        memory_gib: state.settings.memory_gib,
        disk_gib: state.settings.disk_gib,
        write_budget_gib: 64,
        shares: []
      }

      %{
        state
        | vm: %{state.vm | exists?: true},
          image: %{state.image | tag: "box:1"},
          created_spec: :erlang.phash2(spec)
      }
    end)

    assert Sandbox.snapshot(username).vm.stale?
  end

  test "a new root disk size needs the VM recreated", %{username: username} do
    pid = GenServer.whereis(Store.via(Server, username))

    # The spec the VM was created with: today's settings, image box:1.
    :sys.replace_state(pid, fn state ->
      spec = %{
        name: state.vm.name,
        image: "box:1",
        shell: "/bin/bash",
        cpus: state.settings.cpus,
        memory_gib: state.settings.memory_gib,
        disk_gib: state.settings.disk_gib,
        mounts: :none
      }

      %{
        state
        | vm: %{state.vm | exists?: true},
          image: %{state.image | tag: "box:1"},
          created_spec: :erlang.phash2(spec)
      }
    end)

    refute Sandbox.snapshot(username).vm.stale?
    assert {:ok, _settings} = Sandbox.update_settings(username, %{"disk_gib" => "128"})
    assert Sandbox.snapshot(username).vm.stale?
    assert %{disk_gib: 128} = Sandbox.snapshot(username).settings
  end

  test "a bigger disk the VM keeps needs no recreate: it grows at the next start", %{
    username: username
  } do
    pid = GenServer.whereis(Store.via(Server, username))

    :sys.replace_state(pid, fn state ->
      spec = %{
        name: state.vm.name,
        image: "box:1",
        shell: "/bin/bash",
        cpus: state.settings.cpus,
        memory_gib: state.settings.memory_gib,
        disk_gib: state.settings.disk_gib,
        mounts: :none
      }

      %{
        state
        | vm: %{state.vm | exists?: true},
          image: %{state.image | tag: "box:1"},
          created_spec: :erlang.phash2(spec)
      }
    end)

    assert {:ok, %{work_gib: 128, home_gib: 16, cache_gib: 64}} =
             Sandbox.update_settings(username, %{"work_gib" => "128"})

    refute Sandbox.snapshot(username).vm.stale?
    assert {:error, %{home_gib: _}} = Sandbox.update_settings(username, %{"home_gib" => "0"})
  end

  test "creating checks the choices before touching anything", %{username: username} do
    assert Sandbox.recreate_vm(username) == {:error, :no_image}

    pid = GenServer.whereis(Store.via(Server, username))

    :sys.replace_state(pid, fn state ->
      %{state | image: %{state.image | loaded?: true, tag: "box:2026-11-12.1"}}
    end)

    assert Sandbox.recreate_vm(username, %{home: {:snapshot, "gone"}}) == {:error, :no_snapshot}
    assert Sandbox.recreate_vm(username, %{cache: :burn}) == {:error, :bad_options}
    assert Sandbox.snapshot(username).vm.busy == nil
  end

  test "the VM's memory is reached through the VM, while it runs", %{username: username} do
    pid = GenServer.whereis(Store.via(Server, username))

    # Its memory is on its disk: stopped, there is nothing to read or replace.
    assert Sandbox.vm_memories(username) == {:error, :not_running}
    assert Sandbox.seed_memory(username) == {:error, :not_running}

    # Running, it is read through msb, which this test hasn't.
    :sys.replace_state(pid, &%{&1 | vm: %{&1.vm | exists?: true, status: :running}})
    assert {:error, "The VM's memory couldn't be read: " <> _} = Sandbox.vm_memories(username)

    # What you reviewed is remembered here, whatever the VM holds.
    assert :ok = Sandbox.dismiss_memories(username, 2)
    assert Sandbox.snapshot(username).memory.reviewed == 2
  end

  test "a token grant's carriers are the headers its value travels in, authorization unless named",
       %{username: username} do
    base = Map.put(@github, "value", "ghp_real_value_0123456789")
    {:ok, plain} = Sandbox.create_grant(username, base)
    assert plain.carriers == []
    assert MWTClient.Sandbox.Grant.carriers(plain) == ["authorization"]

    {:ok, named} =
      Sandbox.create_grant(
        username,
        Map.merge(base, %{"name" => "Named", "carriers" => "X-Api-Key, Authorization"})
      )

    assert named.carriers == ["x-api-key", "authorization"]

    assert {:error, %{carriers: message}} =
             Sandbox.create_grant(
               username,
               Map.merge(base, %{"name" => "Bad", "carriers" => "X Api Key"})
             )

    assert message =~ "Header names"

    assert {:error, %{carriers: message}} =
             Sandbox.create_grant(
               username,
               Map.merge(base, %{"name" => "Host", "carriers" => "Host"})
             )

    assert message =~ "says how a request is sent"

    # A grant saved before carriers existed travels in authorization.
    saved = plain |> Map.from_struct() |> Map.delete(:carriers)

    assert MWTClient.Sandbox.Grant.carriers(MWTClient.Sandbox.Grant.upgrade(saved)) == [
             "authorization"
           ]
  end

  test "grants check what each type needs, and values never leave the server", %{
    username: username
  } do
    assert {:error, %{kind: _}} = Sandbox.create_grant(username, %{"name" => "x"})

    assert {:error, errors} = Sandbox.create_grant(username, %{"kind" => "token", "name" => ""})
    assert Map.keys(errors) |> Enum.sort() == [:hosts, :name, :purpose, :value]

    assert {:error, %{env: _, hosts: _, prefix: _}} =
             Sandbox.create_grant(
               username,
               Map.merge(@github, %{
                 "env" => "BAD-NAME",
                 "hosts" => "https://x.com",
                 "prefix" => "a b",
                 "value" => "v"
               })
             )

    assert {:error, %{destinations: _}} =
             Sandbox.create_grant(username, %{
               "kind" => "network",
               "name" => "VPN",
               "purpose" => "Grafana",
               "destinations" => "10.0.0.0/99"
             })

    grant = github(username)
    assert String.starts_with?(grant.placeholder, "ghp_")
    assert grant.preset == "github" and grant.git
    refute inspect(Sandbox.snapshot(username)) =~ "ghp_real_value_0123456789"
    assert Sandbox.snapshot(username).values[grant.id]
  end

  test "every use waits by default; requests without a placeholder pass untouched",
       %{username: username} do
    grant = github(username, :ask)

    plain = %{request(grant) | headers: [{"accept", "*/*"}]}
    # Nothing swapped in, so nothing to look for in the answer; what the
    # VM sends next is still looked through for real values.
    assert {:forward, [{"accept", "*/*"}], %{replace: %{answer: []}, out: out}} =
             authorize(username, plain)

    assert MWTClient.Sandbox.Secrets.find(out, "x ghp_real_value_0123456789") ==
             {:value, "GitHub"}

    read = authorize_async(username, request(grant))
    approval = wait_for_approval(username)
    assert approval.kind == :request
    assert approval.request.headers == request(grant).headers
    :ok = Sandbox.decide(username, approval.id, :allow_once)

    assert {:forward, headers, %{replace: %{answer: [back]}}} = Task.await(read)
    assert {"authorization", "token ghp_real_value_0123456789"} in headers
    assert {"user-agent", "gh"} in headers
    # In the answer, the value comes back to the VM as its placeholder.
    assert %{label: {:value, "GitHub"}, to: placeholder, from: forms} = back
    assert placeholder == grant.placeholder
    assert "ghp_real_value_0123456789" in forms
  end

  test "Basic credentials are swapped inside, as git sends them", %{username: username} do
    grant = github(username)
    basic = "Basic " <> Base.encode64("x-access-token:#{grant.placeholder}")

    assert {:forward, [{"authorization", swapped}], _} =
             authorize(
               username,
               request(grant, %{headers: [{"authorization", basic}], path: "/o/r.git/info/refs"})
             )

    assert swapped == "Basic " <> Base.encode64("x-access-token:ghp_real_value_0123456789")
  end

  test "a placeholder sent to another host is blocked and logged", %{username: username} do
    grant = github(username)

    assert {:deny, 403, body} = authorize(username, request(grant, %{host: "paste.example.net"}))
    assert body =~ "mwt_placeholder_blocked"
    outcomes = username |> Sandbox.events() |> Enum.map(& &1.outcome)
    assert :violation in outcomes
    # And the firewall isolated the VM on it.
    assert :firewall in outcomes
  end

  test "an off grant refuses with a reason the agent can read", %{username: username} do
    grant = github(username)
    {:ok, _} = Sandbox.turn_off(username, grant.id)

    assert {:deny, 403, body} = authorize(username, request(grant))

    assert %{"code" => "mwt_grant_off", "grant" => "GitHub", "error" => error} =
             Jason.decode!(body)

    assert error =~ "mwt request #{grant.id}"
  end

  test "a push waits for you; retries join it; allowing answers all of them", %{
    username: username
  } do
    grant = github(username, :ask)

    push =
      request(grant, %{host: "github.com", method: "POST", path: "/o/r.git/git-receive-pack"})

    first = authorize_async(username, push)
    approval = wait_for_approval(username)
    retry = authorize_async(username, push)

    Enum.find_value(1..100, fn _ ->
      if hd(Sandbox.snapshot(username).waiting).retries == 1,
        do: true,
        else: Process.sleep(10) && nil
    end)

    assert Sandbox.waiting_count(username) == 1
    :ok = Sandbox.decide(username, approval.id, :allow_once)

    assert {:forward, headers, _} = Task.await(first)
    assert {:forward, ^headers, _} = Task.await(retry)
    assert {"authorization", "token ghp_real_value_0123456789"} in headers
    assert Sandbox.waiting_count(username) == 0
  end

  test "two requests MWT holds only the start of the body of never share a card", %{
    username: username
  } do
    grant = github(username, :ask)
    start = String.duplicate("a", 64 * 1024)

    # The same start, and a Content-Length saying more is to come: what
    # follows may differ, so each gets a card of its own.
    upload =
      request(grant, %{
        method: "PUT",
        path: "/repos/o/r/contents/big",
        headers: [
          {"authorization", "Bearer " <> grant.placeholder},
          {"content-length", "200000"}
        ],
        body: start
      })

    first = authorize_async(username, upload)
    _card = wait_for_approval(username)
    second = authorize_async(username, upload)

    waiting =
      Enum.find_value(1..100, fn _ ->
        case Sandbox.snapshot(username).waiting do
          [_, _] = waiting -> waiting
          _fewer -> Process.sleep(10) && nil
        end
      end)

    assert Enum.all?(waiting, &(&1.retries == 0))
    for approval <- waiting, do: :ok = Sandbox.decide(username, approval.id, :deny)
    assert {:deny, 403, _} = Task.await(first)
    assert {:deny, 403, _} = Task.await(second)
  end

  test "a request that differs from the waiting card only in its headers gets a card of its own",
       %{username: username} do
    grant = github(username, :ask)
    shown = request(grant)
    shown_held = authorize_async(username, shown)
    card = wait_for_approval(username)

    # The placeholder moved out of its carrier isn't a card at all: it is
    # refused at once.
    moved =
      request(grant, %{
        headers: [{"x-github-api-version", grant.placeholder}, {"user-agent", "gh"}]
      })

    assert {:deny, 403, refused} = authorize(username, moved)
    assert refused =~ "mwt_not_a_carrier"

    # A header added, the same headers in another order: each is another
    # request, not a retry.
    others = [
      request(grant, %{headers: shown.headers ++ [{"x-http-method-override", "DELETE"}]}),
      request(grant, %{headers: Enum.reverse(shown.headers)})
    ]

    held = Enum.map(others, &authorize_async(username, &1))

    waiting =
      Enum.find_value(1..100, fn _ ->
        case Sandbox.snapshot(username).waiting do
          waiting when length(waiting) == 3 -> waiting
          _fewer -> Process.sleep(10) && nil
        end
      end)

    assert %{retries: 0, request: ^shown} = Enum.find(waiting, &(&1.id == card.id))
    assert Enum.all?(waiting, &(&1.retries == 0))

    # Allowing the card lets out the request it shows, and nothing else.
    :ok = Sandbox.decide(username, card.id, :allow_once)
    assert {:forward, _headers, _scan} = Task.await(shown_held)
    assert Sandbox.waiting_count(username) == 2
    assert Enum.all?(held, &(Task.yield(&1, 50) == nil))

    for %{id: id} <- Sandbox.snapshot(username).waiting,
        do: :ok = Sandbox.decide(username, id, :deny)

    assert Enum.all?(held, &match?({:deny, 403, _body}, Task.await(&1)))
  end

  test "denying, allowing similar, and giving up", %{username: username} do
    grant = github(username, :ask)

    push =
      request(grant, %{host: "github.com", method: "POST", path: "/o/r.git/git-receive-pack"})

    denied = authorize_async(username, push)
    :ok = Sandbox.decide(username, wait_for_approval(username).id, :deny)
    assert {:deny, 403, body} = Task.await(denied)
    assert body =~ "mwt_denied_by_user"

    similar = authorize_async(username, push)
    :ok = Sandbox.decide(username, wait_for_approval(username).id, {:allow, :similar, 10})
    assert {:forward, _, _} = Task.await(similar)
    assert {:forward, _, _} = authorize(username, push)

    other =
      request(grant, %{host: "github.com", method: "POST", path: "/o/other.git/git-receive-pack"})

    late = authorize_async(username, other)
    approval = wait_for_approval(username)
    send(Store.whereis(Server, username), {:give_up, approval.id, approval.deadline})
    assert {:deny, 403, body} = Task.await(late)
    assert body =~ "mwt_approval_timeout"
  end

  test "allowing every use lets the waiting ones through, and ends when the grant turns off",
       %{username: username} do
    grant = github(username, :ask)
    push = request(grant, %{method: "POST", path: "/repos/o/r/pulls"})
    read = request(grant, %{path: "/user"})

    held_push = authorize_async(username, push)
    approval = wait_for_approval(username)
    held_read = authorize_async(username, read)

    Enum.find_value(1..100, fn _ ->
      if length(Sandbox.snapshot(username).waiting) == 2, do: true, else: Process.sleep(10) && nil
    end)

    assert Sandbox.decide(username, approval.id, {:turn_on, 10, :ask}) ==
             {:error, :bad_decision}

    :ok = Sandbox.decide(username, approval.id, {:allow, :all, :grant})
    assert {:forward, _, _} = Task.await(held_push)
    assert {:forward, _, _} = Task.await(held_read)
    assert {:forward, _, _} = authorize(username, request(grant, %{path: "/anything"}))

    {:ok, _} = Sandbox.turn_off(username, grant.id)
    assert {:error, :off} = Sandbox.allow_all(username, grant.id, 10)
    assert {:error, :not_found} = Sandbox.allow_all(username, "nope", 10)
    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60)
    assert grant.allowances == []

    {:ok, grant} = Sandbox.allow_all(username, grant.id, 10)
    assert [%{pattern: :all, until: %DateTime{}}] = grant.allowances
    assert {:forward, _, _} = authorize(username, push)
  end

  test "minted values come from the command, and are reused", %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Google",
        "purpose" => "gcloud",
        "hosts" => "*.googleapis.com",
        "file_env" => "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE",
        "source" => "minted",
        "mint" => "echo ya29.minted-$((40 + 2))"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)

    google = %{
      host: "storage.googleapis.com",
      method: "GET",
      path: "/storage/v1/b",
      headers: [{"authorization", "Bearer #{grant.placeholder}"}],
      body: ""
    }

    assert {:forward, [{"authorization", "Bearer ya29.minted-42"}], _} =
             authorize(username, google)

    assert {:forward, [{"authorization", "Bearer ya29.minted-42"}], _} =
             authorize(username, google)
  end

  @tag :tmp_dir
  test "minted per host: each host its own value, told which; expiry says when to mint again", %{
    username: username,
    tmp_dir: dir
  } do
    count = Path.join(dir, "count")

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Per host",
        "purpose" => "Tokens bound to their host",
        "hosts" => "a.example.com, b.example.com",
        "env" => "TOKEN",
        "source" => "minted",
        "mint_per" => "host",
        "mint" =>
          ~s[echo x >> '#{count}'; e=3600; test "$MWT_HOST" = b.example.com && e=30; printf '{"value": "minted-for-%s-%s-%s", "expires_in": %s}' "$MWT_GRANT" "$MWT_HOST" "$(wc -l < '#{count}' | tr -d ' ')" "$e"]
      })

    assert grant.mint_per == :host
    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)

    to = fn host ->
      authorize(username, %{
        host: host,
        method: "GET",
        path: "/",
        headers: [{"authorization", "Bearer #{grant.placeholder}"}],
        body: ""
      })
    end

    assert {:forward, [{"authorization", "Bearer minted-for-per-host-a.example.com-1"}], _} =
             to.("a.example.com")

    assert {:forward, [{"authorization", "Bearer minted-for-per-host-b.example.com-2"}], _} =
             to.("b.example.com")

    # Kept apart, and kept: no mint the second time.
    assert {:forward, [{"authorization", "Bearer minted-for-per-host-a.example.com-1"}], _} =
             to.("a.example.com")

    # b's lasts 30 seconds, less a minute: never fresh, so it mints again.
    assert {:forward, [{"authorization", "Bearer minted-for-per-host-b.example.com-3"}], _} =
             to.("b.example.com")

    # Both are values the proxy looks for.
    server = MWTClient.Vault.Store.whereis(Server, username)
    secrets = MWTClient.Sandbox.Server.Values.secrets(:sys.get_state(server))
    assert MWTClient.Sandbox.Secrets.find(secrets, "x minted-for-per-host-a.example.com-1")
    assert MWTClient.Sandbox.Secrets.find(secrets, "x minted-for-per-host-b.example.com-3")
  end

  test "a grant that keeps minted values at most N minutes mints again sooner than they expire",
       %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Young tokens",
        "purpose" => "A service that takes a token only while it is young",
        "hosts" => "svc.example.com",
        "env" => "TOKEN",
        "source" => "minted",
        "keep_minutes" => "4",
        "mint" => ~s(echo '{"value": "minted-young-value", "expires_in": 3600}')
      })

    assert grant.keep_minutes == 4
    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)

    assert {:forward, [{"authorization", "Bearer minted-young-value"}], _} =
             authorize(username, %{
               host: "svc.example.com",
               method: "GET",
               path: "/",
               headers: [{"authorization", "Bearer #{grant.placeholder}"}],
               body: ""
             })

    # Kept 4 minutes, not the 59 its expiry allows.
    server = MWTClient.Vault.Store.whereis(Server, username)
    {_value, until} = :sys.get_state(server).minted[grant.id]
    assert (until - System.monotonic_time(:millisecond)) in 230_000..240_000

    # Not a number of minutes: said, not dropped.
    assert {:error, %{keep_minutes: _}} =
             Sandbox.update_grant(username, grant.id, %{
               "name" => grant.name,
               "purpose" => grant.purpose,
               "hosts" => "svc.example.com",
               "env" => "TOKEN",
               "mint" => "echo x",
               "keep_minutes" => "soon"
             })
  end

  test "a mint printing JSON with no value fails, with why", %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Broken",
        "purpose" => "x",
        "hosts" => "api.example.com",
        "source" => "minted",
        "mint" => ~s(echo '{"expires_in": 60}')
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)

    assert {:deny, 502, body} =
             authorize(username, %{
               host: "api.example.com",
               method: "GET",
               path: "/",
               headers: [{"authorization", "Bearer #{grant.placeholder}"}],
               body: ""
             })

    assert body =~ "mwt_mint_failed"
    assert Enum.any?(Sandbox.events(username), &(&1.summary =~ ~s(no "value")))
  end

  # QA M6: the value is put in when the mint ends, and the grant is looked
  # at again then. Turned off while its command ran, nothing goes out.
  @tag :tmp_dir
  test "a grant turned off while its value is minted sends nothing", %{
    username: username,
    tmp_dir: dir
  } do
    go = Path.join(dir, "go")

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Minted",
        "purpose" => "A slow mint",
        "hosts" => "api.example.com",
        "env" => "MINTED_TOKEN",
        "source" => "minted",
        "mint" => "while [ ! -e '#{go}' ]; do sleep 0.02; done; echo MINTED_REAL_VALUE_42"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)

    request = %{
      host: "api.example.com",
      method: "GET",
      path: "/user",
      headers: [{"authorization", "Bearer #{grant.placeholder}"}],
      body: ""
    }

    sent = authorize_async(username, request)
    server = MWTClient.Vault.Store.whereis(Server, username)

    assert Enum.find_value(1..250, fn _ ->
             Map.has_key?(:sys.get_state(server).minting, grant.id) or
               (Process.sleep(10) && false)
           end)

    {:ok, _} = Sandbox.turn_off(username, grant.id)
    File.write!(go, "")

    assert {:deny, 403, body} = Task.await(sent, 10_000)
    assert %{"code" => "mwt_grant_off"} = Jason.decode!(body)
    refute body =~ "MINTED_REAL_VALUE_42"
  end

  # The same for a lock: the credential is looked at again when the mint
  # ends, and a lock taken while its command ran keeps the value in.
  @tag :tmp_dir
  test "a credential locked while its value is minted sends nothing", %{
    username: username,
    tmp_dir: dir
  } do
    go = Path.join(dir, "go")

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Minted",
        "purpose" => "A slow mint",
        "hosts" => "api.example.com",
        "env" => "MINTED_TOKEN",
        "source" => "minted",
        "mint" => "while [ ! -e '#{go}' ]; do sleep 0.02; done; echo MINTED_REAL_VALUE_42"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)

    request = %{
      host: "api.example.com",
      method: "GET",
      path: "/user",
      headers: [{"authorization", "Bearer #{grant.placeholder}"}],
      body: ""
    }

    sent = authorize_async(username, request)
    server = MWTClient.Vault.Store.whereis(Server, username)

    assert Enum.find_value(1..250, fn _ ->
             Map.has_key?(:sys.get_state(server).minting, grant.credential) or
               Map.has_key?(:sys.get_state(server).minting, grant.id) or
               (Process.sleep(10) && false)
           end)

    :ok = Sandbox.lock(username, {:credential, grant.credential})
    File.write!(go, "")

    assert {:deny, 403, body} = Task.await(sent, 10_000)
    assert %{"code" => "mwt_locked"} = Jason.decode!(body)
    refute body =~ "MINTED_REAL_VALUE_42"
  end

  test "destinations: public passes, private needs a grant, refused needs an exact one",
       %{username: username} do
    destination = fn ip, port -> Server.call(username, {:destination, ip, port}) end

    # A public address is the Internet's; with its grant off, nothing gives
    # it, a token grant's host included.
    assert destination.({140, 82, 112, 3}, 443) == {:ok, "internet"}
    {:ok, _} = Sandbox.turn_off(username, "internet")
    assert {:deny, words} = destination.({140, 82, 112, 3}, 443)
    assert words =~ "Internet would open it, and is off"

    assert Enum.any?(
             Sandbox.events(username),
             &(&1.summary =~ "140.82.112.3:443 · Internet would open it, and is off")
           )

    {:ok, _} = Sandbox.turn_on(username, "internet", :until_off, :all)
    assert destination.({140, 82, 112, 3}, 443) == {:ok, "internet"}
    assert {:deny, _} = destination.({10, 20, 4, 12}, 5432)
    assert {:deny, _} = destination.({127, 0, 0, 1}, 5433)

    {:ok, tunnel} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "preset" => "database",
        "name" => "Tunnel",
        "purpose" => "The database",
        "destinations" => "127.0.0.1:5433\n10.20.0.0/16:5432"
      })

    {:ok, _} = Sandbox.turn_on(username, tunnel.id, 60)

    held =
      Task.async(fn ->
        Server.call(username, {:destination, {10, 20, 4, 12}, 5432}, :infinity)
      end)

    approval = wait_for_approval(username)
    assert approval.kind == :connection
    assert {"Listed as", "10.20.0.0/16:5432"} in approval.facts
    :ok = Sandbox.decide(username, approval.id, :allow_once)
    assert Task.await(held) == {:ok, tunnel.id}

    {:ok, _} = Sandbox.allow_all(username, tunnel.id, :grant)
    assert destination.({127, 0, 0, 1}, 5433) == {:ok, tunnel.id}
    assert {:deny, _} = destination.({127, 0, 0, 1}, 4000)
    assert destination.({10, 20, 4, 12}, 5432) == {:ok, tunnel.id}
  end

  # Each held request keeps what MWT read of it and shows on every page:
  # the VM decides how many it sends, so how many wait is bounded.
  test "requests waiting for you are bounded, and so are the callers held on one", %{
    username: username
  } do
    grant = github(username, :ask)
    most = MWTClient.Sandbox.Server.Approvals.max_waiting_uses()
    held = for i <- 1..most, do: authorize_async(username, request(grant, %{path: "/r/#{i}"}))
    waiting = fn -> Sandbox.snapshot(username).waiting end
    Enum.find(1..200, fn _ -> length(waiting.()) == most or (Process.sleep(10) && false) end)
    assert length(waiting.()) == most

    assert {:deny, 429, body} = authorize(username, request(grant, %{path: "/r/more"}))
    assert %{"code" => "mwt_too_many_waiting", "by" => "MWT agent sandbox"} = Jason.decode!(body)
    assert length(waiting.()) == most

    # Retries of one join it, up to as many callers as one may hold.
    callers = MWTClient.Sandbox.Server.Approvals.max_waiters()
    joined = for _ <- 2..callers, do: authorize_async(username, request(grant, %{path: "/r/1"}))
    first = fn -> Enum.find(waiting.(), &(&1.path == "/r/1")) end
    Enum.find(1..200, fn _ -> first.().retries == callers - 1 or (Process.sleep(10) && false) end)
    assert first.().retries == callers - 1
    assert {:deny, 429, _body} = authorize(username, request(grant, %{path: "/r/1"}))

    # Deciding frees the place.
    :ok = Sandbox.decide(username, first.().id, :deny)
    for task <- [hd(held) | joined], do: assert({:deny, 403, _} = Task.await(task))
    assert length(waiting.()) == most - 1
    assert authorize_async(username, request(grant, %{path: "/r/again"}))
    Enum.find(1..200, fn _ -> length(waiting.()) == most or (Process.sleep(10) && false) end)
    assert length(waiting.()) == most
  end

  test "connections waiting for you are bounded too", %{username: username} do
    {:ok, tunnel} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "preset" => "database",
        "name" => "Tunnel",
        "purpose" => "The database",
        "destinations" => "10.20.0.0/16:5432"
      })

    {:ok, _} = Sandbox.turn_on(username, tunnel.id, 60)
    most = MWTClient.Sandbox.Server.Approvals.max_waiting_uses()

    for i <- 1..most do
      Task.async(fn -> Server.call(username, {:destination, {10, 20, 4, i}, 5432}, :infinity) end)
    end

    waiting = fn -> Sandbox.snapshot(username).waiting end
    Enum.find(1..200, fn _ -> length(waiting.()) == most or (Process.sleep(10) && false) end)
    assert length(waiting.()) == most
    assert {:deny, why} = Server.call(username, {:destination, {10, 20, 5, 1}, 5432})
    assert why =~ "Too many wait"
  end

  ## Agents asking

  defp ask(username, attrs),
    do:
      Server.call(
        username,
        {:request_access, Map.merge(%{reason: "push the fix", agent: "claude"}, attrs)}
      )

  defp await(username, id, ms \\ 5_000),
    do: Task.async(fn -> Server.call(username, {:await, id, ms}, ms + 1_000) end)

  test "an agent's ask waits as an activation; turning it on answers the agent", %{
    username: username
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value_0123456789"))

    assert {:error, :unknown_grant} = ask(username, %{grant: "gitlab"})
    assert {:error, :no_reason} = ask(username, %{grant: grant.id, reason: " "})
    assert {:error, :bad_minutes} = ask(username, %{grant: grant.id, minutes: 0})
    assert {:error, :nothing_asked} = ask(username, %{})

    assert {:ok, %{kind: :activation, minutes: 30} = approval} =
             ask(username, %{grant: "github", minutes: 30})

    # By name too, and asking again joins the same card.
    assert {:ok, %{id: same, retries: 1}} = ask(username, %{grant: "GITHUB", minutes: 30})
    assert same == approval.id
    assert Sandbox.waiting_count(username) == 1

    waiting = await(username, approval.id)
    Process.sleep(20)

    assert Sandbox.decide(username, approval.id, :allow_once) == {:error, :bad_decision}
    :ok = Sandbox.decide(username, approval.id, {:turn_on, 15, :ask})

    assert {:ok, %{status: :allowed, decision: {:turn_on, 15, :ask}}, %{state: :on} = on} =
             Task.await(waiting)

    assert DateTime.diff(on.expires_at, DateTime.utc_now()) in 880..900
    assert on.allowances == []
    assert {:already_on, _} = ask(username, %{grant: grant.id})
    assert [%{summary: summary} | _] = Sandbox.events(username)
    assert summary =~ "asked by claude"
  end

  test "an agent that stops waiting hears pending; the ask stays; allow-all comes with it",
       %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value_0123456789"))

    {:ok, approval} = ask(username, %{grant: grant.id})

    assert {:pending, %{id: id, status: :waiting}} = Task.await(await(username, approval.id, 30))
    assert id == approval.id
    assert [%{status: :waiting}] = Sandbox.snapshot(username).waiting

    waiting = await(username, approval.id)
    Process.sleep(20)
    :ok = Sandbox.decide(username, approval.id, {:turn_on, :until_off, :all})
    assert {:ok, _, %{expires_at: nil, allowances: [%{pattern: :all}]}} = Task.await(waiting)

    # A settled ask answers at once.
    assert {:ok, %{status: :allowed}, _} = Task.await(await(username, approval.id))
    assert {:error, :not_found} = Task.await(await(username, "ask-nope"))
  end

  test "declining, giving up, turning on yourself, and removing the grant answer the agent", %{
    username: username
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value_0123456789"))

    {:ok, declined} = ask(username, %{grant: grant.id})
    waiting = await(username, declined.id)
    Process.sleep(20)
    :ok = Sandbox.decide(username, declined.id, :decline)
    assert {:ok, %{status: :denied, decision: :decline}, _} = Task.await(waiting)

    {:ok, late} = ask(username, %{grant: grant.id})
    send(Store.whereis(Server, username), {:give_up, late.id, late.deadline})
    assert {:ok, %{status: :timed_out}, _} = Task.await(await(username, late.id))

    {:ok, mine} = ask(username, %{grant: grant.id})
    waiting = await(username, mine.id)
    Process.sleep(20)
    {:ok, _} = Sandbox.turn_on(username, grant.id, 60)
    assert {:ok, %{status: :allowed}, %{state: :on}} = Task.await(waiting)

    {:ok, _} = Sandbox.turn_off(username, grant.id)
    {:ok, gone} = ask(username, %{grant: grant.id})
    :ok = Sandbox.delete_grant(username, grant.id)

    assert {:ok, %{status: :denied, decision: :grant_off}, nil} =
             Task.await(await(username, gone.id))
  end

  test "an ask for something new is answered by setting a grant up", %{username: username} do
    {:ok, approval} =
      ask(username, %{need: "Read access to the staging Postgres at 10.1.2.3:5432", minutes: 45})

    assert approval.grant_id == nil and approval.title == "Access you haven't set up"
    assert Sandbox.decide(username, approval.id, {:set_up, "nope"}) == {:error, :bad_decision}

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Staging DB",
        "purpose" => "Staging Postgres",
        "destinations" => "10.1.2.3:5432"
      })

    waiting = await(username, approval.id)
    Process.sleep(20)
    :ok = Sandbox.decide(username, approval.id, {:set_up, grant.id})
    assert {:ok, %{status: :allowed}, %{id: id, state: :on} = on} = Task.await(waiting)
    assert id == grant.id
    assert DateTime.diff(on.expires_at, DateTime.utc_now()) in 2680..2700
  end

  test "agents can't flood you: ten asks wait at most", %{username: username} do
    for n <- 1..10, do: assert({:ok, _} = ask(username, %{need: "thing #{n}"}))
    assert {:error, :too_many} = ask(username, %{need: "one more"})
    assert {:ok, %{retries: 1}} = ask(username, %{need: "thing 3"})
  end

  test "grants saved before types and presets are brought up to date" do
    old = %{
      __struct__: MWTClient.Sandbox.Grant,
      id: "google",
      name: "Google",
      recipe: :google,
      kind: :http,
      placeholder: "ya29.mwtx",
      env: ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"],
      hosts: ["*.googleapis.com"],
      rules: [:whatever],
      default_action: :ask,
      per_connection: :allow,
      allowances: [
        %{__struct__: MWTClient.Sandbox.Allowance, id: "a", pattern: "GET x", until: nil}
      ],
      source: {:minted, "gcloud auth print-access-token"},
      state: :on
    }

    upgraded = MWTClient.Sandbox.Grant.upgrade(old)
    assert %MWTClient.Sandbox.Grant{kind: :token, preset: :google, env: []} = upgraded
    assert upgraded.file_env == ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"]
    assert upgraded.purpose =~ "Google Cloud"
    refute Map.has_key?(upgraded, :rules)
    assert [%MWTClient.Sandbox.Allowance{pattern: "GET x"}] = upgraded.allowances

    github = MWTClient.Sandbox.Grant.upgrade(%{old | recipe: :github, env: ["GH_TOKEN"]})
    assert github.git and github.env == ["GH_TOKEN"] and github.preset == :github
  end

  test "grants and values survive locking", %{username: username, key: key} do
    grant = github(username)
    :ok = Store.close(username)
    :ok = Store.open(username, key)

    assert [%{id: id, placeholder: placeholder}] =
             Enum.reject(Sandbox.snapshot(username).grants, &MWTClient.Sandbox.Grant.built_in?/1)

    assert id == grant.id and placeholder == grant.placeholder
    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)

    assert {:forward, [{"authorization", "token ghp_real_value_0123456789"} | _], _} =
             authorize(username, request(grant))
  end

  describe "when MWT starts" do
    alias MWTClient.Sandbox.Grant

    defp restart(username, key) do
      :ok = Store.close(username)
      :ok = Store.open(username, key)
    end

    defp token(username),
      do: Enum.find(Sandbox.snapshot(username).grants, &(&1.kind == :token))

    test "every grant goes to its own setting, and what the session left is gone", %{
      username: username,
      key: key
    } do
      # On for an hour, every use allowed: a session's state.
      grant = github(username)
      assert Grant.auto_approved?(token(username))

      # Off is the default: nothing carries over.
      restart(username, key)

      assert %{state: :off, start: :off, allowances: [], expires_at: nil} = token(username)

      # Starts on: on at once, until turned off, every use asking.
      {:ok, on} = Sandbox.set_start(username, grant.id, :on)
      assert %{state: :on, start: :on, expires_at: nil, allowances: []} = on
      {:ok, _} = Sandbox.turn_off(username, grant.id)
      restart(username, key)
      assert %{state: :on, start: :on, allowances: []} = token(username)
      refute Grant.auto_approved?(token(username))

      # Always on: every use goes through, now and after every start,
      # whatever the session did to it in between.
      {:ok, always} = Sandbox.set_start(username, grant.id, :auto)
      assert always.state == :on and Grant.auto_approved?(always)
      {:ok, _} = Sandbox.turn_off(username, grant.id)
      restart(username, key)
      assert Grant.auto_approved?(token(username))

      assert {:forward, [{"authorization", "token ghp_real_value_0123456789"} | _], _} =
               authorize(username, request(grant))

      # Back to off: off at once.
      {:ok, off} = Sandbox.set_start(username, grant.id, :off)
      assert %{state: :off, start: :off, allowances: []} = off
      restart(username, key)
      assert %{state: :off} = token(username)
    end

    test "a grant starts off, on and asking, or on and auto-approved", %{username: username} do
      grant = github(username)
      assert Grant.starts(grant) == [:off, :on, :auto]
      # On: every use then asks.
      assert {:ok, %{state: :on, allowances: []}} = Sandbox.set_start(username, grant.id, :on)
      assert {:error, :not_found} = Sandbox.set_start(username, "nope", :on)
    end

    test "a grant over a host, and a token grant a saved command runs with, stay as they are",
         %{username: username, key: key} do
      {:ok, host} =
        Sandbox.create_grant(username, %{
          "kind" => "network",
          "network" => "internet",
          "name" => "Example",
          "purpose" => "One host, asked about",
          "destinations" => "example.com"
        })

      {:ok, stripe} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Stripe",
          "purpose" => "Test charges",
          "hosts" => "api.stripe.com",
          "env" => "STRIPE_KEY",
          "value" => "sk_test_real"
        })

      {:ok, _} =
        Sandbox.create_grant(username, %{
          "kind" => "command",
          "name" => "charge",
          "purpose" => "Uses the key",
          "script" => "true",
          "dir" => System.user_home!(),
          "confined" => "true",
          "with" => stripe.credential
        })

      restart(username, key)

      snapshot = Sandbox.snapshot(username)

      assert %{scope: ["example.com"]} =
               Enum.find(snapshot.grants, &(&1.id == host.id))

      assert %{limits: %{rules: []}} = Enum.find(snapshot.networks, &(&1.id == "internet"))
      # The saved command covers Stripe's key: the token grant is as it was.
      assert %{kind: :token, credential: credential} =
               Enum.find(snapshot.grants, &(&1.id == stripe.id))

      assert credential == stripe.credential
    end

    test "a setting that turns it on answers an agent waiting for it; off answers nobody", %{
      username: username
    } do
      {:ok, grant} =
        Sandbox.create_grant(username, Map.put(@github, "value", "ghp_real_value_0123456789"))

      {:ok, ask} =
        Server.call(username, {:request_access, %{grant: grant.id, reason: "push the fix"}})

      {:ok, _} = Sandbox.set_start(username, grant.id, :off)
      assert [%{id: id, status: :waiting}] = Sandbox.snapshot(username).waiting
      assert id == ask.id

      {:ok, _} = Sandbox.set_start(username, grant.id, :on)
      assert Sandbox.snapshot(username).waiting == []
      assert [%{id: ^id, status: :allowed}] = Sandbox.snapshot(username).history
    end

    test "choosing always on lets through what waited on the grant", %{username: username} do
      grant = github(username, :ask)
      held = Task.async(fn -> authorize(username, request(grant)) end)

      assert Enum.find_value(1..200, fn _ ->
               case Sandbox.snapshot(username).waiting do
                 [approval] -> approval
                 _ -> Process.sleep(10) && nil
               end
             end)

      {:ok, _} = Sandbox.set_start(username, grant.id, :auto)

      assert {:forward, [{"authorization", "token ghp_real_value_0123456789"} | _], _} =
               Task.await(held)
    end
  end

  test "crash reports and status dumps never carry values or keys", %{username: username} do
    github(username)
    status = :sys.get_status(Store.whereis(Server, username))

    refute inspect(status, limit: :infinity, printable_limit: :infinity) =~
             "ghp_real_value_0123456789"

    assert inspect(status, limit: :infinity) =~ ":redacted"
  end

  test "the inbox holds placeholders and git's answers, never stored values", %{
    username: username
  } do
    grant = github(username)
    inbox = Sandbox.snapshot(username).inbox

    refute File.read!(Path.join(inbox, "env.sh")) =~ "export "

    assert File.read!(Path.join(inbox, "grant-env/#{grant.id}.sh")) =~
             "GITHUB_TOKEN='#{grant.placeholder}'"

    assert File.read!(Path.join(inbox, "git/#{grant.id}")) =~ "github.com\n"

    refute inbox
           |> Path.join("**/*")
           |> Path.wildcard()
           |> Enum.any?(&(File.regular?(&1) and File.read!(&1) =~ "ghp_real_value_0123456789"))
  end

  describe "the built-in grants" do
    alias MWTClient.Sandbox.Grant
    alias MWTClient.Sandbox.Server.Grants

    test "are MWT's tools, the Internet's and Commands agents write" do
      token = %Grant{id: "gh", name: "GitHub", kind: :token}
      assert [^token | others] = Grants.with_built_in([token])
      {mwt_tools, [internet, written]} = Enum.split_with(others, &Grant.mwt_tools?/1)

      assert Enum.map(mwt_tools, & &1.id) ==
               ~w(mwt-read mwt-create mwt-change git-fetch git-fetch-remote git-handoff share-sync workspace)

      assert %Grant{id: "internet", internet: true, state: :on} = internet

      # On, asking: it can be turned off, never made to let a run through
      # unasked.
      assert %Grant{id: "agent-commands", kind: :agent_commands, state: :on, allowances: []} =
               written

      assert Grant.starts(written) == [:off, :on]
      assert Grant.always_asks?(written)
    end

    test "Commands agents write takes no allowance, however asked", %{username: username} do
      {:ok, _} = Sandbox.set_start(username, "agent-commands", :on)
      assert {:error, :always_asks} = Sandbox.set_start(username, "agent-commands", :auto)
      {:ok, _} = Sandbox.turn_on(username, "agent-commands", :until_off, :all)
      {:ok, _} = Sandbox.set_mode(username, "agent-commands", :all)

      written = Enum.find(Sandbox.snapshot(username).grants, &(&1.id == "agent-commands"))
      assert %Grant{state: :on, allowances: []} = written
      refute Grant.auto_approved?(written)
    end

    test "a running server brings its state up to date when its code changes", %{
      username: username
    } do
      _ = Sandbox.snapshot(username)
      pid = Store.whereis(Server, username)

      # As it was before grants had their `minutes`, under code that has
      # them: what compiling again in development leaves a running server
      # with.
      :sys.replace_state(pid, fn state ->
        old =
          Map.delete(
            %Grant{
              id: "say",
              name: "say",
              kind: :command,
              purpose: "old words",
              script: "echo hi",
              dir: "/"
            },
            :minutes
          )

        state
        |> Map.put(:grants, [old])
        |> Map.delete(:code)
        |> Map.delete(:notified_handoffs)
      end)

      assert {:ok, grant} = Sandbox.turn_on(username, "say", 30, :ask)
      assert %Grant{id: "say", state: :on, minutes: 30} = grant
      assert Store.whereis(Server, username) == pid

      # The built-in ones are back, MWT's own.
      assert Enum.any?(Sandbox.snapshot(username).grants, &Grant.internet?/1)
    end
  end
end
