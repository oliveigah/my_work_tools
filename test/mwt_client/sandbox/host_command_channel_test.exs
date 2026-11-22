defmodule MWTClient.Sandbox.HostCommandChannelTest do
  @moduledoc """
  Host commands end to end: the `mwt` command in the VM (here, with a fake
  socat), the channel, the server's approval, the run on this machine, and
  what the agent hears back.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Grant
  alias MWTClient.Sandbox.Channel

  @cli Path.expand("../../../priv/sandbox/mwt-cli", __DIR__)

  # Stands in for socat: sends stdin to the Unix socket the address names,
  # then prints everything until MWT closes.
  @fake_socat """
  #!/usr/bin/env python3
  import socket, sys
  address = sys.argv[-1]
  assert address.startswith("UNIX-CONNECT:"), address
  data = sys.stdin.buffer.read()
  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  s.connect(address[len("UNIX-CONNECT:"):])
  s.sendall(data)
  while True:
      chunk = s.recv(65536)
      if not chunk:
          break
      sys.stdout.buffer.write(chunk)
  """

  setup do
    base = Path.join(System.tmp_dir!(), "mwt-run-#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    project = Path.join(base, "project")
    File.mkdir_p!(bin)
    File.mkdir_p!(project)
    File.write!(Path.join(bin, "socat"), @fake_socat)
    File.chmod!(Path.join(bin, "socat"), 0o755)
    on_exit(fn -> File.rm_rf!(base) end)

    context =
      "commands"
      |> MWTClient.VaultHelpers.unlocked_identity()
      |> Map.merge(%{bin: bin, project: project})

    # Commands go through a command grant: here one that takes any text.
    # Ask to run commands, the escape hatch, is built in.
    grant = Enum.find(Sandbox.snapshot(context.username).grants, &Grant.ask_to_run?/1)

    {:ok, _} = Sandbox.turn_on(context.username, grant.id, :until_off, :ask)
    context
  end

  defp mwt(context, args, opts \\ []) do
    {input, opts} = Keyword.pop(opts, :input)

    env = [
      {"PATH", context.bin <> ":" <> System.get_env("PATH")},
      {"MWT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(context.username)},
      {"MWT_AGENT", "claude"},
      {"MWT_THREAD", "Ship the release"},
      {"CLAUDE_CODE_SESSION_ID", nil},
      {"CLAUDE_PID", nil},
      {"CODEX_THREAD_ID", nil}
    ]

    if input do
      # A script on stdin: run through a shell so the CLI's stdin is a pipe.
      script_file = Path.join(context.bin, "stdin-#{System.unique_integer([:positive])}")
      File.write!(script_file, input)
      quoted = Enum.map_join([@cli | args], " ", &shell_quote/1)

      System.cmd("bash", ["-c", "bash #{quoted} < #{shell_quote(script_file)}"],
        env: env,
        cd: Keyword.get(opts, :cd, context.project)
      )
    else
      System.cmd("bash", [@cli | args],
        env: env,
        cd: Keyword.get(opts, :cd, context.project),
        stderr_to_stdout: Keyword.get(opts, :stderr, true)
      )
    end
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  defp waiting(username, fun) do
    Enum.find_value(1..300, fn _ ->
      case Enum.find(Sandbox.snapshot(username).waiting, fun) do
        nil -> Process.sleep(10) && nil
        approval -> approval
      end
    end) || flunk("nothing like that waited")
  end

  defp command(username), do: waiting(username, &(&1.kind == :command and &1.stage == :run))

  defp output_card(username),
    do: waiting(username, &(&1.kind == :command and &1.stage == :output))

  defp share(context) do
    {:ok, share} = Sandbox.add_share(context.username, context.project)
    share.path
  end

  test "mwt host describes this machine and the shares", context do
    shared = share(context)
    {:ok, _} = Sandbox.update_settings(context.username, %{"host_notes" => "VPN: openvpn3 work"})

    {output, 0} = mwt(context, ["host"])
    assert output =~ "# The user's machine"
    assert output =~ "Architecture: #{:erlang.system_info(:system_architecture)}"
    assert output =~ "- #{shared}\n"
    assert output =~ "In the VM each is a read-only copy"
    assert output =~ "VPN: openvpn3 work"

    inbox = Sandbox.snapshot(context.username).inbox
    assert File.read!(Path.join(inbox, "host.md")) == String.trim_trailing(output) <> "\n"
  end

  test "an approved command runs in the shared folder, and its status and output come back",
       context do
    shared = share(context)
    File.write!(Path.join(shared, "input.txt"), "from the VM\n")

    asking =
      Task.async(fn ->
        mwt(
          context,
          [
            "run",
            "commands",
            "--reason",
            "read the input",
            "--",
            "cat input.txt; pwd; exit 7"
          ],
          stderr: false
        )
      end)

    approval = command(context.username)
    assert approval.script == "cat input.txt; pwd; exit 7"
    assert approval.dir == shared
    assert approval.agent == "claude"
    assert %{title: "Ship the release", id: nil, folder: folder} = approval.thread
    assert is_binary(folder)
    assert approval.claims == [{"Reason", "read the input"}]
    assert approval.id =~ ~r/^run-/

    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {output, 7} = Task.await(asking, 10_000)
    assert output == "from the VM\n#{shared}\n"

    [decided] = Sandbox.snapshot(context.username).history
    assert decided.run.exit == 7
    assert decided.decision == {:run, :send}
  end

  test "several arguments are quoted for the shell; one is a shell line; none reads stdin",
       context do
    asking =
      Task.async(fn ->
        mwt(
          context,
          ["run", "commands", "--reason", "r", "--", "printf", "%s|", "a b", "c;d", "$HOME"],
          stderr: false
        )
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {"a b|c;d|$HOME|", 0} = Task.await(asking, 10_000)

    asking =
      Task.async(fn ->
        mwt(context, ["run", "commands", "--reason", "r"], input: "echo one\necho two\n")
      end)

    approval = command(context.username)
    assert approval.script == "echo one\necho two"
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {"one\ntwo\n", 0} = Task.await(asking, 10_000)

    # Output keeps its trailing newlines, or their absence.
    asking =
      Task.async(fn ->
        mwt(context, ["run", "commands", "--reason", "r", "--", "printf 'x\\n\\n\\n'"],
          stderr: false
        )
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {"x\n\n\n", 0} = Task.await(asking, 10_000)
  end

  test "outside a share it runs in the home folder", context do
    asking =
      Task.async(fn ->
        mwt(context, ["run", "commands", "--reason", "r", "--", "pwd"], stderr: false)
      end)

    approval = command(context.username)
    assert approval.dir == System.user_home!()
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    assert {output, 0} = Task.await(asking, 10_000)
    assert output == System.user_home!() <> "\n"
  end

  test "the output can wait for you, who send it or keep it", context do
    {output, 120} =
      mwt(context, ["run", "commands", "--reason", "r", "--wait", "0", "--", "echo secret"])

    [_, id] = Regex.run(~r/mwt wait (run-\S+)/, output)

    :ok = Sandbox.decide(context.username, id, {:run, :review})
    card = output_card(context.username)
    assert card.id == id
    assert card.run.output == "secret\n"
    assert card.run.exit == 0

    {output, 120} = mwt(context, ["wait", id, "--wait", "0"])
    assert output =~ "looking at its output"

    # Whether the wait arrives before or after the decision, it gets the output.
    waiting = Task.async(fn -> mwt(context, ["wait", id], stderr: false) end)
    :ok = Sandbox.decide(context.username, id, :send_output)
    assert {"secret\n", 0} = Task.await(waiting, 10_000)

    # Kept: the agent hears it ran, not what it printed.
    asking =
      Task.async(fn ->
        mwt(context, ["run", "commands", "--reason", "r", "--", "echo hidden; exit 3"])
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :review})
    card = output_card(context.username)
    :ok = Sandbox.decide(context.username, card.id, :keep_output)
    assert {output, 121} = Task.await(asking, 10_000)
    assert output =~ "It ran (exit 3), but the user kept its output"
    refute output =~ "hidden"
  end

  test "an output nobody releases is kept; the first wait's timer doesn't end the second",
       context do
    server = MWTClient.Vault.Store.whereis(MWTClient.Sandbox.Server, context.username)

    {_, 120} =
      mwt(context, ["run", "commands", "--reason", "r", "--wait", "0", "--", "echo private"])

    asked = command(context.username)
    :ok = Sandbox.decide(context.username, asked.id, {:run, :review})
    card = output_card(context.username)
    assert DateTime.compare(card.deadline, asked.deadline) != :lt

    # A timer set for an earlier deadline, like the one from when it was
    # asked, leaves the output waiting.
    send(server, {:give_up, card.id, DateTime.add(card.deadline, -1, :second)})
    _ = :sys.get_state(server)
    assert output_card(context.username).id == card.id

    send(server, {:give_up, card.id, card.deadline})
    {output, 121} = mwt(context, ["wait", card.id])
    assert output =~ "didn't release its output"
    refute output =~ "private"
  end

  test "a declined command doesn't run", context do
    marker = Path.join(context.project, "ran")

    asking =
      Task.async(fn ->
        mwt(context, ["run", "commands", "--reason", "r", "--", "touch #{marker}"])
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, :decline)
    assert {output, 121} = Task.await(asking, 10_000)
    assert output =~ "declined"
    refute File.exists?(marker)
    assert {:error, :not_waiting} = Sandbox.decide(context.username, approval.id, {:run, :send})
  end

  test "commands accept only their own decisions", context do
    {_, 120} = mwt(context, ["run", "commands", "--reason", "r", "--wait", "0", "--", "true"])
    approval = command(context.username)

    for decision <- [
          :allow_once,
          {:allow, :similar, 10},
          {:allow, :all, :grant},
          :send_output,
          {:run, :forever}
        ] do
      assert {:error, :bad_decision} = Sandbox.decide(context.username, approval.id, decision)
    end
  end

  test "the same command asked again joins the waiting one", context do
    {_, 120} = mwt(context, ["run", "commands", "--reason", "r", "--wait", "0", "--", "date"])

    {_, 120} =
      mwt(context, ["run", "commands", "--reason", "again", "--wait", "0", "--", "date"])

    {_, 120} =
      mwt(context, [
        "run",
        "commands",
        "--reason",
        "r",
        "--wait",
        "0",
        "--timeout",
        "5",
        "--",
        "date"
      ])

    waiting = Sandbox.snapshot(context.username).waiting
    assert [%{retries: 1}, %{retries: 0}] = Enum.sort_by(waiting, & &1.retries, :desc)
  end

  test "a running command can be stopped", context do
    asking =
      Task.async(fn ->
        mwt(context, [
          "run",
          "commands",
          "--reason",
          "r",
          "--wait",
          "30",
          "--",
          "echo started; sleep 60"
        ])
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})

    running =
      Enum.find_value(1..300, fn _ ->
        case Sandbox.snapshot(context.username).running do
          [running] -> running
          [] -> Process.sleep(10) && nil
        end
      end)

    assert running.id == approval.id
    :ok = Sandbox.stop_command(context.username, approval.id)

    assert {output, status} = Task.await(asking, 10_000)
    assert status in [124, 137, 143]
    assert output =~ "the user stopped it"
    assert {:error, :not_running} = Sandbox.stop_command(context.username, approval.id)
    assert Sandbox.snapshot(context.username).running == []
  end

  test "wrong asks and an unreachable MWT have their own statuses", context do
    assert {output, 122} = mwt(context, ["run", "commands", "--", "true"])
    assert output =~ "Say why"

    assert {_, 122} =
             mwt(context, ["run", "commands", "--reason", "r", "--timeout", "0", "--", "true"])

    assert {_, 122} =
             mwt(context, ["run", "commands", "--reason", "r", "--timeout", "x", "--", "true"])

    assert {_, 122} =
             mwt(context, ["run", "commands", "--reason", "r", "--bogus", "--", "true"])

    assert {output, 122} =
             mwt(context, [
               "run",
               "commands",
               "--reason",
               "r",
               "--",
               String.duplicate("x", 16_385)
             ])

    assert output =~ "16 KiB"

    unreachable = %{context | username: "nobody-#{System.unique_integer([:positive])}"}
    assert {_, 123} = mwt(unreachable, ["run", "commands", "--reason", "r", "--", "true"])
    assert {_, 123} = mwt(unreachable, ["wait", "run-abc"])
    assert {_, 4} = mwt(unreachable, ["wait", "ask-abc"])
  end

  test "status dumps and crash reports never carry a command's output", context do
    asking =
      Task.async(fn ->
        mwt(context, ["run", "commands", "--reason", "r", "--", "echo dump-$((6 * 7))"])
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    {"dump-42\n", 0} = Task.await(asking, 10_000)

    server = MWTClient.Vault.Store.whereis(MWTClient.Sandbox.Server, context.username)
    status = :sys.get_status(server)
    refute inspect(status, limit: :infinity, printable_limit: :infinity) =~ "dump-42"
  end

  test "the activity log says what happened, never the output", context do
    asking =
      Task.async(fn ->
        mwt(context, ["run", "commands", "--reason", "r", "--", "echo top-secret-$((40 + 2))"])
      end)

    approval = command(context.username)
    :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
    {_, 0} = Task.await(asking, 10_000)

    events = Sandbox.events(context.username, %{group: "commands"})
    summaries = Enum.map(events, & &1.summary)
    assert Enum.any?(summaries, &(&1 =~ "you ran it, output to the agent"))
    assert Enum.any?(summaries, &(&1 =~ "exit 0"))
    refute Enum.any?(summaries, &(&1 =~ "top-secret-42"))
  end

  describe "a command grant" do
    test "Ask to run commands is built in: it can't be removed, and off it runs nothing",
         context do
      assert {:error, :built_in} = Sandbox.delete_grant(context.username, "commands")

      assert [%{id: "commands", script: nil}] =
               Enum.reject(
                 Sandbox.snapshot(context.username).grants,
                 &(&1.kind == :mwt or MWTClient.Sandbox.Grant.internet?(&1))
               )

      {:ok, _} = Sandbox.turn_off(context.username, "commands")
      assert {output, 122} = mwt(context, ["run", "commands", "--reason", "r", "--", "true"])
      assert output =~ "commands is off"
      assert output =~ "mwt request commands"
      assert Sandbox.snapshot(context.username).waiting == []
    end

    test "must be named, exist and be on", context do
      assert {output, 122} = mwt(context, ["run", "--reason", "r", "--", "true"])
      assert output =~ "Name the command grant" and output =~ "commands"

      assert {output, 122} = mwt(context, ["run", "nope", "--reason", "r", "--", "true"])
      assert output =~ "No command grant by that name"

      assert {output, 122} = mwt(context, ["run", "commands", "extra", "--reason", "r"])
      assert output =~ "put the command after --"

      {:ok, _} = Sandbox.turn_off(context.username, "commands")
      assert {output, 122} = mwt(context, ["run", "commands", "--reason", "r", "--", "true"])
      assert output =~ "commands is off" and output =~ "mwt request commands"
      assert Sandbox.snapshot(context.username).waiting == []
    end

    test "the id it had as Any command still works, and the agent hears the new one", context do
      asking =
        Task.async(fn ->
          mwt(context, ["run", "any-command", "--reason", "r", "--", "echo hi"])
        end)

      approval = command(context.username)
      assert approval.grant_id == "commands"
      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {output, 0} = Task.await(asking)
      assert output =~ "hi"
      assert output =~ "any-command is called commands now"

      assert {output, 0} = mwt(context, ["request", "any-command", "--reason", "r"])
      assert output =~ "already on" and output =~ "any-command is called commands now"
    end

    test "never lets a run through unasked", context do
      assert Sandbox.allow_all(context.username, "commands", 10) == {:error, :every_run_asks}
      {:ok, _} = Sandbox.turn_off(context.username, "commands")
      {:ok, grant} = Sandbox.turn_on(context.username, "commands", 60, :all)
      assert grant.allowances == []

      asking =
        Task.async(fn ->
          mwt(context, ["run", "commands", "--reason", "r", "--", "echo hi"])
        end)

      approval = command(context.username)
      assert approval.grant_id == "commands"
      assert {"Grant", "Ask to run commands"} in approval.facts
      assert {"Script", "The agent's, exactly as shown"} in approval.facts
      :ok = Sandbox.decide(context.username, approval.id, :decline)
      assert {_, 121} = Task.await(asking)
    end

    test "with a script of yours runs only that, in its folder, and takes no text", context do
      File.write!(Path.join(context.project, "marker.txt"), "in the grant's folder\n")

      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "show",
          "purpose" => "Show the marker",
          "script" => "cat marker.txt; pwd",
          "dir" => context.project
        })

      assert %{script: "cat marker.txt; pwd", kind: :command} = grant
      {:ok, _} = Sandbox.turn_on(context.username, "show", :until_off, :ask)

      assert {output, 122} = mwt(context, ["run", "show", "--reason", "r", "--", "rm -rf /"])
      assert output =~ "runs the user's own script: send no command"

      # Asked from another folder: it still runs where you said.
      asking =
        Task.async(fn ->
          mwt(context, ["run", "show", "--reason", "see it"],
            cd: System.tmp_dir!(),
            stderr: false
          )
        end)

      approval = command(context.username)
      assert approval.script == "cat marker.txt; pwd"
      assert {"Script", "Yours, saved as show"} in approval.facts
      assert {"Where that is", "The folder you set on the grant."} in approval.facts
      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {output, 0} = Task.await(asking)
      assert output =~ "in the grant's folder"
      assert output =~ Path.basename(context.project)
    end

    test "with a script needs a folder that exists", context do
      assert {:error, %{dir: "Say which folder your script runs in."}} =
               Sandbox.create_grant(context.username, %{
                 "kind" => "command",
                 "name" => "deploy",
                 "purpose" => "Deploy",
                 "script" => "./deploy.sh"
               })

      assert {:error, %{dir: "That folder does not exist on this machine."}} =
               Sandbox.create_grant(context.username, %{
                 "kind" => "command",
                 "name" => "deploy",
                 "purpose" => "Deploy",
                 "script" => "./deploy.sh",
                 "dir" => "/no/such/folder"
               })
    end
  end

  describe "Ask to run commands and saved commands" do
    test "a run through Ask to run commands saved from its card tells the agent to use it by name",
         context do
      asking =
        Task.async(fn ->
          mwt(
            context,
            [
              "run",
              "commands",
              "--reason",
              "list the pods",
              "--suggest-save",
              "pods",
              "--save-for",
              "Lists the pods of the web namespace",
              "--",
              "echo pod-a"
            ],
            stderr: true
          )
        end)

      approval = command(context.username)
      assert approval.script_from == :agent
      assert approval.suggest_save == "pods"
      assert approval.save_for == "Lists the pods of the web namespace"
      # The agent's suggestion is its claim, not a fact.
      assert {"Save it as", "pods"} in approval.claims
      assert {"Saved, it is for", "Lists the pods of the web namespace"} in approval.claims

      {:ok, saved} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "preset" => "saved_command",
          "name" => "pods",
          "purpose" => approval.save_for,
          "script" => approval.script,
          "dir" => approval.dir
        })

      # Saved off, like any grant; from a card it turns on for an hour, asking each time.
      assert saved.state == :off
      {:ok, _} = Sandbox.turn_on(context.username, saved.id, 60, :ask)
      :ok = Sandbox.command_saved(context.username, approval.id, saved.id)
      assert %{saved_as: "pods"} = command(context.username)

      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {output, 0} = Task.await(asking)
      assert output =~ "pod-a"
      assert output =~ "the user's subgrant pods now"
      assert output =~ ~s(mwt call pods --reason "...")

      # Next time it runs by name, without the escape hatch.
      :ok = Sandbox.turn_off(context.username, "commands") |> elem(0)

      asking =
        Task.async(fn -> mwt(context, ["run", "pods", "--reason", "again"], stderr: false) end)

      approval = command(context.username)
      assert approval.script_from == :grant
      assert approval.script == "echo pod-a"
      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {"pod-a\n", 0} = Task.await(asking)
    end

    test "a suggestion to save needs its own words, apart from the reason", context do
      assert {output, 122} =
               mwt(context, [
                 "run",
                 "commands",
                 "--reason",
                 "list the pods",
                 "--suggest-save",
                 "pods",
                 "--",
                 "echo pod-a"
               ])

      assert output =~ "--suggest-save needs --save-for"
      assert Sandbox.snapshot(context.username).waiting == []
    end

    test "only a run through Ask to run commands can be saved from its card", context do
      {:ok, _} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "show",
          "purpose" => "Show",
          "script" => "echo hi",
          "dir" => context.project
        })

      {:ok, _} = Sandbox.turn_on(context.username, "show", 60, :ask)

      asking =
        Task.async(fn ->
          mwt(context, ["run", "show", "--reason", "r", "--suggest-save", "x"])
        end)

      approval = command(context.username)
      # The agent's suggestion means nothing for a script that is yours already.
      assert approval.suggest_save == nil
      assert {:error, :not_found} = Sandbox.command_saved(context.username, approval.id, "show")
      :ok = Sandbox.decide(context.username, approval.id, :decline)
      Task.await(asking)
    end

    test "the same text as a saved command says so, and the agent hears its name", context do
      {:ok, _} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "Who am I",
          "purpose" => "Says who runs it",
          "script" => "echo same",
          "dir" => System.user_home!()
        })

      # Outside a share, an ask runs in the home folder: the saved one's folder.
      asking =
        Task.async(fn ->
          mwt(context, ["run", "commands", "--reason", "r", "--", "echo same"])
        end)

      approval = command(context.username)
      assert approval.saved_as == "who-am-i"
      assert Enum.any?(approval.hints, &(&1 =~ "Same as your subgrant Who am I"))
      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {output, 0} = Task.await(asking)
      assert output =~ "mwt call who-am-i"
    end

    test "asking for a simpler one declines it and tells the agent to work in the VM", context do
      script = "kubectl get pods | grep web | awk '{print $1}' | sort | uniq"

      asking =
        Task.async(fn -> mwt(context, ["run", "commands", "--reason", "r", "--", script]) end)

      approval = command(context.username)
      assert Enum.any?(approval.hints, &(&1 =~ "Long for a command you check by eye"))
      :ok = Sandbox.decide(context.username, approval.id, :simpler)
      assert {output, 121} = Task.await(asking)
      assert output =~ "Send the smallest command that gets the raw data"
      assert output =~ "here in the VM"
    end

    test "a saved command auto-approved runs at once, logged, and the agent hears so", context do
      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "hello",
          "purpose" => "Say hello",
          "script" => "echo hello from the host",
          "dir" => context.project
        })

      {:ok, grant} = Sandbox.turn_on(context.username, grant.id, 60, :all)
      assert [%{pattern: :all, until: nil}] = grant.allowances

      {output, 0} = mwt(context, ["grants"])

      assert output =~
               ~r/`mwt call hello` · on until \d\d:\d\d UTC \(\d+ min left\), runs without asking/

      # No card: it ran, and its output came straight back.
      assert {"hello from the host\n", 0} =
               mwt(context, ["run", "hello", "--reason", "greet"], stderr: false)

      assert Sandbox.snapshot(context.username).waiting == []
      assert [%{decision: :auto, status: :allowed}] = Sandbox.snapshot(context.username).history

      summaries =
        Enum.map(Sandbox.events(context.username, %{group: "commands"}), & &1.summary)

      assert Enum.any?(summaries, &(&1 =~ "auto-approved, output to the agent"))
      assert Enum.any?(summaries, &(&1 =~ "exit 0"))
    end

    test "an auto-approved run that prints a stored value, or a key, waits for you",
         context do
      value = "stripe_real_value_0123456789"

      {:ok, _} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "name" => "Stripe",
          "purpose" => "Test charges",
          "hosts" => "api.stripe.com",
          "value" => value
        })

      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "leaky",
          "purpose" => "Prints what it shouldn't",
          "script" => "echo first line; cat secret.txt; echo AKIAIOSFODNN7EXAMPLE",
          "dir" => context.project
        })

      File.write!(Path.join(context.project, "secret.txt"), value <> "\n")
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)

      asking =
        Task.async(fn -> mwt(context, ["run", "leaky", "--reason", "r"], stderr: false) end)

      card = output_card(context.username)
      assert card.run.held

      assert card.run.findings == [
               %{what: {:value, "Stripe"}, line: 2},
               %{what: {:shape, "an AWS access key"}, line: 3}
             ]

      # The log and the firewall say what, never the text.
      summaries = Enum.map(Sandbox.events(context.username), & &1.summary)
      assert Enum.any?(summaries, &(&1 =~ "output held for you: Stripe's real value, line 2"))
      refute Enum.any?(summaries, &(&1 =~ value))

      :ok = Sandbox.decide(context.username, card.id, :keep_output)
      assert {output, 121} = Task.await(asking, 10_000)
      refute output =~ value
    end

    @tag :bwrap
    test "confined, it runs with a grant's real value and none of your home; without a value, it says why",
         context do
      value = "stripe_real_value_0123456789"

      {:ok, stripe} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "name" => "Stripe",
          "purpose" => "Test charges",
          "hosts" => "api.stripe.com",
          "env" => "STRIPE_KEY",
          "file_env" => "STRIPE_KEY_FILE",
          "value" => value
        })

      home = Application.fetch_env!(:mwt_client, MWTClient.Sandbox.HostRun)[:home]
      File.mkdir_p!(home)
      File.write!(Path.join(home, "mine"), "a file of yours")

      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "charge",
          "purpose" => "Uses the key",
          "script" =>
            ~S[test "$STRIPE_KEY" = "$(cat "$STRIPE_KEY_FILE")" && echo same; cat "$HOME/mine" 2>/dev/null || echo "no home"],
          "dir" => context.project,
          "confined" => "true",
          "with" => stripe.id
        })

      assert %{confined: true, with: ["stripe"]} = grant
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :ask)

      asking =
        Task.async(fn -> mwt(context, ["call", "charge", "--reason", "r"], stderr: false) end)

      approval = command(context.username)
      assert {"Runs", "Confined, with the value of: Stripe"} in approval.facts
      :ok = Sandbox.decide(context.username, approval.id, {:run, :review})

      # The script printed nothing of the value, so it isn't held for it.
      card = output_card(context.username)
      assert card.run.output == "same\nno home\n"
      assert card.run.findings == []
      :ok = Sandbox.decide(context.username, card.id, :send_output)
      assert {"same\nno home\n", 0} = Task.await(asking, 10_000)

      # A grant with no value ends the run before it starts.
      Sandbox.snapshot(context.username)
      pid = MWTClient.Vault.Store.whereis(MWTClient.Sandbox.Server, context.username)
      :sys.replace_state(pid, &%{&1 | values: Map.delete(&1.values, stripe.id)})

      asking = Task.async(fn -> mwt(context, ["call", "charge", "--reason", "r"]) end)
      approval = command(context.username)
      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {output, 121} = Task.await(asking, 10_000)
      assert output =~ "Stripe has no value yet"
    end

    test "with names token grants, and only for a confined command", context do
      base = %{
        "kind" => "command",
        "name" => "x",
        "purpose" => "x",
        "script" => "true",
        "dir" => context.project
      }

      assert {:error, %{with: message}} =
               Sandbox.create_grant(
                 context.username,
                 Map.merge(base, %{"confined" => "true", "with" => "nope"})
               )

      assert message =~ "nope isn't one"

      assert {:error, %{with: "Only a confined command" <> _}} =
               Sandbox.create_grant(context.username, Map.put(base, "with", "commands"))
    end

    test "auto-approve can start while a run waits, which then runs; off, every run asks again",
         context do
      {:ok, _} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "hello",
          "purpose" => "Say hello",
          "script" => "echo hi",
          "dir" => context.project
        })

      {:ok, _} = Sandbox.turn_on(context.username, "hello", 60, :ask)

      asking =
        Task.async(fn -> mwt(context, ["run", "hello", "--reason", "r"], stderr: false) end)

      assert %{script_from: :grant} = command(context.username)
      {:ok, _} = Sandbox.allow_all(context.username, "hello", :grant)
      assert {"hi\n", 0} = Task.await(asking)

      {:ok, _} = Sandbox.turn_off(context.username, "hello")
      {:ok, grant} = Sandbox.turn_on(context.username, "hello", :until_off)
      assert grant.allowances == []

      assert {_, 120} = mwt(context, ["run", "hello", "--reason", "r", "--wait", "0"])
      assert %{status: :waiting} = command(context.username)
    end
  end

  describe "a subgrant, called by id" do
    defp subgrant(context, attrs \\ %{}) do
      {:ok, grant} =
        Sandbox.create_grant(
          context.username,
          Map.merge(
            %{
              "kind" => "command",
              "name" => "say",
              "purpose" => "Says a word and a number of times",
              "script" => ~s(echo "said: $WORD x$TIMES"),
              "params" => "WORD: word: what to say\nTIMES: number: how many times",
              "dir" => context.project
            },
            attrs
          )
        )

      grant
    end

    test "is a subgrant of Ask to run commands, with a switch of its own", context do
      grant = subgrant(context)
      built_in = Enum.find(Sandbox.snapshot(context.username).grants, &Grant.ask_to_run?/1)

      assert grant.parent == built_in.id and Grant.subgrant?(grant)
      assert [%{name: "WORD", shape: :word}, %{name: "TIMES", shape: :number}] = grant.params
      assert grant.state == :off

      # Its grant off, it still runs once it is on itself.
      {:ok, _} = Sandbox.turn_off(context.username, built_in.id)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :ask)

      asking =
        Task.async(fn ->
          mwt(context, ["call", "say", "WORD=feature/login", "TIMES=3", "--reason", "try it"],
            stderr: false
          )
        end)

      approval = command(context.username)
      # The script is yours, as saved; all the agent chose is the values.
      assert approval.script == ~s(echo "said: $WORD x$TIMES")
      assert approval.script_from == :grant
      assert approval.values == [{"WORD", "feature/login"}, {"TIMES", "3"}]
      assert approval.title =~ "WORD=feature/login TIMES=3"

      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      # It read them as variables.
      assert {"said: feature/login x3\n", 0} = Task.await(asking)
    end

    test "a call is checked before it waits: every value given, known, and of its shape",
         context do
      grant = subgrant(context)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)

      for {args, says} <- [
            {["WORD=hello"], "TIMES is missing"},
            {["WORD=hello", "TIMES=3", "EXTRA=1"], "It has no parameter EXTRA"},
            {["WORD=hello", "TIMES=three"], "TIMES isn't of its shape"},
            {["WORD=hello world", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=--help", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=../../etc/passwd", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=/etc/passwd", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=$(id)", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=a;id", "TIMES=3"], "WORD isn't of its shape"}
          ] do
        assert {output, 122} = mwt(context, ["call", "say"] ++ args ++ ["--reason", "r"])
        assert output =~ says, inspect(args)
        assert output =~ "mwt call say WORD=… TIMES=…"
      end

      # Nothing ran, and nothing waits.
      snapshot = Sandbox.snapshot(context.username)
      assert snapshot.waiting == [] and snapshot.history == []
    end

    test "a value never becomes part of the script, whatever it holds", context do
      marker = Path.join(context.project, "pwned")

      grant =
        subgrant(context, %{
          "name" => "note",
          "script" => ~s(echo "note: $NOTE"),
          "params" => "NOTE: text: the note"
        })

      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)
      value = ~s[x"; touch #{marker}; echo "$(touch #{marker}) `touch #{marker}`]

      assert {output, 0} =
               mwt(context, ["call", "note", "NOTE=" <> value, "--reason", "r"], stderr: false)

      # Printed as it was sent, and run as nothing.
      assert output == "note: " <> value <> "\n"
      refute File.exists?(marker)
    end

    test "always on runs without a card, with its values in the log", context do
      grant = subgrant(context)
      {:ok, grant} = Sandbox.set_start(context.username, grant.id, :auto)
      assert grant.state == :on and grant.start == :auto and Grant.auto_approved?(grant)

      assert {"said: hi x2\n", 0} =
               mwt(context, ["call", "say", "WORD=hi", "TIMES=2", "--reason", "r"], stderr: false)

      assert Sandbox.snapshot(context.username).waiting == []

      summaries =
        Enum.map(Sandbox.events(context.username, %{group: "commands"}), & &1.summary)

      assert Enum.any?(summaries, &(&1 =~ "WORD=hi TIMES=2" and &1 =~ "auto-approved"))
    end

    test "off, it is refused, and says how to ask for it", context do
      subgrant(context)
      assert {output, 122} = mwt(context, ["call", "say", "WORD=a", "TIMES=1", "--reason", "r"])
      assert output =~ "say is off"
      assert output =~ "mwt request say"
    end

    test "takes an id, never a command or a name", context do
      grant = subgrant(context)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)

      # A call sends no text.
      assert {output, 122} =
               mwt(context, ["call", "say", "--reason", "r", "--", "echo", "mine"])

      assert output =~ "a call sends no command"

      # Ask to run commands is no subgrant, and takes no values.
      assert {output, 122} = mwt(context, ["call", "commands", "--reason", "r"])
      assert output =~ "commands is no subgrant"

      # Its name, in another case, names nothing.
      assert {output, 122} = mwt(context, ["call", "Say", "WORD=a", "TIMES=1", "--reason", "r"])
      assert output =~ "No subgrant has the id Say"
    end

    test "an ad-hoc command with a subgrant's exact text still waits, like any other", context do
      grant = subgrant(context, %{"name" => "plain", "script" => "echo plain", "params" => ""})
      {:ok, _} = Sandbox.set_start(context.username, grant.id, :auto)

      asking =
        Task.async(fn ->
          mwt(context, ["run", "commands", "--reason", "r", "--", "echo plain"],
            cd: context.project
          )
        end)

      # Never recognised as the subgrant: a card, with a hint naming it.
      approval = command(context.username)
      assert approval.script_from == :agent and approval.status == :waiting
      :ok = Sandbox.decide(context.username, approval.id, :decline)
      assert {_output, 121} = Task.await(asking)
    end

    test "a parameter must be read by the script, and can't take a name that means something",
         context do
      for {params, script, says} <- [
            {"WORD: word: a word", "echo fixed", "doesn't read WORD"},
            {"PATH: word: a path", ~s(echo "$PATH"), "already means something"},
            {"GIT_SSH_COMMAND: text: x", ~s(git fetch "$GIT_SSH_COMMAND"), "already means"},
            {"word: word: lowercase", ~s(echo "$word"), "in capitals"},
            {"WORD: sentence: x", ~s(echo "$WORD"), "is no shape"},
            {"WORD: word", ~s(echo "$WORD"), "say what it is"},
            {"WORD: word: a\nWORD: number: b", ~s(echo "$WORD"), "there twice"}
          ] do
        assert {:error, %{params: message}} =
                 Sandbox.create_grant(context.username, %{
                   "kind" => "command",
                   "name" => "bad",
                   "purpose" => "Bad",
                   "script" => script,
                   "params" => params,
                   "dir" => context.project
                 })

        assert message =~ says, params
      end
    end
  end

  describe "a subgrant an agent proposes" do
    defp propose(context, extra \\ []) do
      mwt(
        context,
        [
          "propose",
          "commands",
          "--name",
          "repo view",
          "--for",
          "Shows a repository",
          "--param",
          "REPO_NAME:word:the repository, as owner/name",
          "--reason",
          "I look at several"
        ] ++ extra ++ ["--", ~s(echo "viewing $REPO_NAME")]
      )
    end

    defp proposed(username, id),
      do: Enum.find(Sandbox.snapshot(username).grants, &(&1.id == id))

    test "is saved at once, off and to review; accepting it on its page answers with its id",
         context do
      # Nothing has to be on.
      built_in = Enum.find(Sandbox.snapshot(context.username).grants, &Grant.ask_to_run?/1)
      {:ok, _} = Sandbox.turn_off(context.username, built_in.id)

      asking = Task.async(fn -> propose(context) end)
      ask = waiting(context.username, &(&1.kind == :activation))
      assert ask.title == "Review repo view"
      assert %{kind: :command, parent_name: "Ask to run commands", updated: false} = ask.proposal

      grant = proposed(context.username, ask.grant_id)

      assert %Grant{
               parent: parent,
               name: "repo view",
               purpose: "Shows a repository",
               script: ~s(echo "viewing $REPO_NAME"),
               params: [%{name: "REPO_NAME", shape: :word}],
               state: :off,
               start: :off,
               proposal: %{agent: "claude", reason: "I look at several", reviewed_at: nil}
             } = grant

      assert parent == built_in.id
      assert Grant.to_review?(grant)
      # Confined, as one you add starts.
      assert grant.confined
      assert grant.proposal.thread.title == "Ship the release"

      # Nothing turns it on before you accept it: not its switch, not the card.
      assert {:error, :to_review} = Sandbox.turn_on(context.username, grant.id, 60)

      assert {:error, :bad_decision} =
               Sandbox.decide(context.username, ask.id, {:turn_on, 60, :ask})

      assert {:error, :every_run_asks} = Sandbox.set_start(context.username, grant.id, :on)

      # The agent is told where it is and that it waits.
      assert Sandbox.snapshot(context.username).waiting |> Enum.any?(&(&1.id == ask.id))

      {:ok, accepted} = Sandbox.review(context.username, grant.id, {60, :ask})
      refute Grant.to_review?(accepted)
      assert Grant.proposed?(accepted)
      assert accepted.state == :on

      assert {output, 0} = Task.await(asking)
      assert output =~ "Saved as repo-view, off, for the user to review"
      assert output =~ "accepted it as repo-view"
      assert output =~ ~s(mwt call repo-view REPO_NAME=… --reason "why now")

      # On for the time it asked, each call asking.
      called =
        Task.async(fn ->
          mwt(context, ["call", "repo-view", "REPO_NAME=oliveigah/klife", "--reason", "r"],
            stderr: false
          )
        end)

      approval = command(context.username)
      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {"viewing oliveigah/klife\n", 0} = Task.await(called)

      # Accepted, it is the user's: reviewing again is refused.
      assert {:error, :reviewed} = Sandbox.review(context.username, grant.id, :keep_off)
    end

    test "one in a shared folder is saved to run there", context do
      shared = Path.join(context.project, "docs")
      File.mkdir_p!(shared)
      {:ok, share} = Sandbox.add_share(context.username, shared)

      assert {_output, 2} = propose(context, ["--wait", "0", "--dir", shared])
      ask = waiting(context.username, &(&1.kind == :activation))
      assert proposed(context.username, ask.grant_id).dir == share.path
    end

    test "proposed again under its name before review, it changes in place", context do
      assert {_output, 2} = propose(context, ["--wait", "0"])
      ask = waiting(context.username, &(&1.kind == :activation))
      first = proposed(context.username, ask.grant_id)

      assert {output, 2} =
               mwt(context, [
                 "propose",
                 "commands",
                 "--name",
                 "Repo View",
                 "--for",
                 "Shows a repository, as JSON",
                 "--reason",
                 "again",
                 "--wait",
                 "0",
                 "--",
                 "gh repo view --json name"
               ])

      assert output =~ "Your proposal repo-view is changed"
      changed = proposed(context.username, first.id)
      assert changed.script == "gh repo view --json name"
      assert changed.purpose == "Shows a repository, as JSON"
      assert Enum.count(Sandbox.snapshot(context.username).grants, &Grant.to_review?/1) == 1

      # One ask waits for it, asked twice.
      assert [%{retries: 1}] =
               Enum.filter(Sandbox.snapshot(context.username).waiting, &(&1.grant_id == first.id))
    end

    test "accepted and kept off, it waits for its switch; its ask is answered when it turns on",
         context do
      asking = Task.async(fn -> propose(context) end)
      ask = waiting(context.username, &(&1.kind == :activation))

      {:ok, accepted} = Sandbox.review(context.username, ask.grant_id, :keep_off)
      assert accepted.state == :off
      refute Grant.to_review?(accepted)
      assert Grant.starts(accepted) == [:off, :on, :auto]

      {:ok, _} = Sandbox.turn_on(context.username, accepted.id, 60)
      assert {output, 0} = Task.await(asking)
      assert output =~ "accepted it as repo-view"
    end

    test "declined, the agent hears so and the proposal is removed", context do
      asking = Task.async(fn -> propose(context) end)
      ask = waiting(context.username, &(&1.kind == :activation))
      :ok = Sandbox.decide(context.username, ask.id, :decline)
      assert {output, 3} = Task.await(asking)
      assert output =~ "declined it, and the proposal is removed"
      refute Enum.any?(Sandbox.snapshot(context.username).grants, &Grant.subgrant?/1)
    end

    test "removed from its page before review, the agent hears it was declined", context do
      asking = Task.async(fn -> propose(context) end)
      ask = waiting(context.username, &(&1.kind == :activation))
      :ok = Sandbox.delete_grant(context.username, ask.grant_id)
      assert {output, 3} = Task.await(asking)
      assert output =~ "declined"
    end

    test "is refused before it waits when it is no function the user could read", context do
      for {args, says} <- [
            {["propose", "commands", "--for", "x", "--reason", "r", "--", "echo a"], "Name it"},
            {["propose", "commands", "--name", "x", "--reason", "r", "--", "echo a"],
             "Say what it does"},
            {["propose", "commands", "--name", "x", "--for", "y", "--", "echo a"], "Say why"},
            {["propose", "commands", "--name", "x", "--for", "y", "--reason", "r"],
             "Give the script"},
            {[
               "propose",
               "commands",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--param",
               "WORD:word:a word",
               "--",
               "echo fixed"
             ], "doesn't read WORD"},
            {[
               "propose",
               "commands",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--param",
               "LD_PRELOAD:text:a library",
               "--",
               ~s(echo "$LD_PRELOAD")
             ], "already means something"},
            {["propose", "nope", "--name", "x", "--for", "y", "--reason", "r", "--", "echo a"],
             "No grant is called"},
            {[
               "propose",
               "commands",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--",
               "echo",
               "$A"
             ], "one argument in single quotes"},
            {["propose", "token", "--name", "x", "--for", "y", "--reason", "r"],
             "--host: List at least one host"},
            {["propose", "network", "--name", "x", "--for", "y", "--reason", "r"],
             "--destination: List at least one"},
            {[
               "propose",
               "token",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--preset",
               "nope"
             ], "No token preset is called nope"},
            {["propose", "token", "--name", "x", "--for", "y", "--reason", "r", "--", "echo a"],
             "takes no script"}
          ] do
        assert {output, 1} = mwt(context, args)
        assert output =~ says, inspect(args)
      end

      assert Sandbox.snapshot(context.username).waiting == []
      refute Enum.any?(Sandbox.snapshot(context.username).grants, &Grant.proposed?/1)
    end
  end

  describe "a grant an agent proposes" do
    test "a token grant: saved off with no value; accepted, it needs one before it turns on",
         context do
      assert {output, 2} =
               mwt(context, [
                 "propose",
                 "token",
                 "--name",
                 "Stripe test",
                 "--for",
                 "Test charges through the Stripe API",
                 "--host",
                 "api.stripe.com",
                 "--env",
                 "STRIPE_API_KEY",
                 "--carrier",
                 "Authorization",
                 "--reason",
                 "The checkout tests call Stripe",
                 "--wait",
                 "0"
               ])

      assert output =~ "Saved as stripe-test, off, for the user to review"
      assert output =~ "mwt wait"

      grant = Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "stripe-test"))

      assert %Grant{
               kind: :token,
               hosts: ["api.stripe.com"],
               env: ["STRIPE_API_KEY"],
               carriers: ["authorization"],
               source: :stored,
               state: :off,
               start: :off
             } = grant

      assert Grant.to_review?(grant)
      refute Sandbox.snapshot(context.username).values["stripe-test"]

      # grants.md says it waits for the user.
      {0, listed} = Channel.answer("grants", %{}, context.username)
      assert listed =~ "proposed by claude and not reviewed yet"

      # No value yet: accepting it can't turn it on.
      assert {:error, :no_value} = Sandbox.review(context.username, grant.id, {60, :ask})
      :ok = Sandbox.set_value(context.username, grant.id, "sk_test_real")
      {:ok, on} = Sandbox.review(context.username, grant.id, {60, :ask})
      assert on.state == :on
    end

    test "a token grant from a preset takes its fields, the agent's overriding them", context do
      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "token",
                 "--name",
                 "GitHub, read-only",
                 "--for",
                 "Reading issues of oliveigah/klife",
                 "--preset",
                 "github",
                 "--host",
                 "api.github.com",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      grant =
        Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "github-read-only"))

      assert grant.hosts == ["api.github.com"]
      assert grant.env == ["GITHUB_TOKEN", "GH_TOKEN"]
      assert grant.git
      assert grant.preset == "github"
      assert grant.cli_tools == ["gh"]
      assert String.starts_with?(grant.placeholder, "ghp_")
    end

    test "a network grant, with its own DNS server and way out", context do
      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "network",
                 "--name",
                 "Staging database",
                 "--for",
                 "Postgres on the staging network",
                 "--destination",
                 "db.staging.corp:5432",
                 "--destination",
                 "10.20.0.0/16:5432",
                 "--resolver",
                 "10.8.0.1",
                 "--via",
                 "wg0",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      grant =
        Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "staging-database"))

      assert %Grant{
               kind: :network,
               destinations: ["db.staging.corp:5432", "10.20.0.0/16:5432"],
               resolver: "10.8.0.1",
               anchor: "wg0",
               state: :off
             } = grant

      assert Grant.to_review?(grant)
      # An ask for it by id makes a card to review, never one that turns it on.
      assert {_output, 2} =
               mwt(context, ["request", grant.id, "--reason", "r", "--wait", "0"])

      ask = waiting(context.username, &(&1.kind == :activation and is_nil(&1.proposal)))
      assert ask.title == "Review Staging database"

      assert {:error, :bad_decision} =
               Sandbox.decide(context.username, ask.id, {:turn_on, 60, :ask})
    end

    test "at most twenty wait for review", context do
      for n <- 1..20 do
        assert {_output, 2} =
                 mwt(context, [
                   "propose",
                   "network",
                   "--name",
                   "net #{n}",
                   "--for",
                   "y",
                   "--destination",
                   "10.0.0.#{n}:22",
                   "--reason",
                   "r",
                   "--wait",
                   "0"
                 ])
      end

      assert {output, 1} =
               mwt(context, [
                 "propose",
                 "network",
                 "--name",
                 "one more",
                 "--for",
                 "y",
                 "--destination",
                 "10.0.1.1:22",
                 "--reason",
                 "r"
               ])

      assert output =~ "Twenty of your proposals"
    end
  end

  describe "a request subgrant" do
    alias MWTClient.Sandbox.{SavedRequest, Server}
    alias MWTClient.Vault.Store

    @value "ghp_real_value_123"

    defp github(context) do
      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "preset" => "github",
          "name" => "GitHub",
          "purpose" => "The GitHub API",
          "hosts" => "api.github.com, github.com",
          "env" => "GH_TOKEN",
          "prefix" => "ghp_",
          "source" => "stored",
          "value" => @value
        })

      grant
    end

    defp pr_view(context, attrs \\ %{}) do
      {:ok, grant} =
        Sandbox.create_grant(
          context.username,
          Map.merge(
            %{
              "kind" => "request",
              "preset" => "request_subgrant",
              "parent" => "github",
              "name" => "pr view",
              "purpose" => "Shows a pull request",
              "method" => "GET",
              "url" => "https://api.github.com/repos/$REPO/pulls/$PR",
              "headers" => SavedRequest.default_headers(:github),
              "params" => "REPO: word: the repository\nPR: number: the pull request"
            },
            attrs
          )
        )

      grant
    end

    # Answers as the service would, and tells the test what it got.
    defp service(context, status \\ 200) do
      test = self()

      Req.Test.stub(SavedRequest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(test, {
          :sent,
          conn.method,
          conn.request_path,
          conn.query_string,
          Plug.Conn.get_req_header(conn, "authorization"),
          body
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, ~s({"number": 7, "echo": "#{@value}"}))
      end)

      # The request goes out from a task of the identity's server.
      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))
    end

    test "is sent by MWT with the real value, once you approve its exact request; the VM gets the answer",
         context do
      grant = github(context)
      sub = pr_view(context)
      assert sub.parent == grant.id and sub.kind == :request and sub.state == :off
      # The token grant stays off: the subgrant has a switch of its own.
      {:ok, _} = Sandbox.turn_on(context.username, sub.id, 60, :ask)
      service(context)

      asking =
        Task.async(fn ->
          mwt(context, ["call", "pr-view", "REPO=oliveigah/klife", "PR=7", "--reason", "review"])
        end)

      approval = command(context.username)
      # Unless the agent gives one, a request's own time limit.
      assert approval.timeout == elem(SavedRequest.timeouts(), 0)
      # The card shows the request as it will go, the token by name.
      assert approval.script =~ "GET https://api.github.com/repos/oliveigah/klife/pulls/7"
      assert approval.script =~ "Authorization: Bearer [GitHub's token]"
      refute approval.script =~ @value
      assert approval.values == [{"REPO", "oliveigah/klife"}, {"PR", "7"}]
      assert {"Request", "Yours, saved as pr view"} in approval.facts

      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {output, 0} = Task.await(asking)

      assert_received {:sent, "GET", "/repos/oliveigah/klife/pulls/7", "", ["Bearer " <> @value],
                       ""}

      # The answer comes back, the value written out of it.
      assert output =~ "HTTP 200 from api.github.com"
      assert output =~ ~s({"number": 7, "echo": "[GitHub's token]"})
      refute output =~ @value

      summaries =
        Enum.map(Sandbox.events(context.username, %{group: "commands"}), & &1.summary)

      assert Enum.any?(summaries, &(&1 =~ "HTTP 200"))
      refute Enum.any?(summaries, &(&1 =~ @value))
    end

    test "another grant's value is written out of an answer in every form; a key in it waits",
         context do
      github(context)
      other = "other/real+value0123456"

      {:ok, _} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "name" => "Hex",
          "purpose" => "Packages",
          "hosts" => "hex.pm",
          "value" => other
        })

      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      encoded = URI.encode_www_form(other)

      Req.Test.stub(SavedRequest, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"a": "#{encoded}", "b": "#{other}"}))
      end)

      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))

      assert {output, 0} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=1", "--reason", "r"],
                 stderr: false
               )

      assert output =~ ~s({"a": "[Hex's token]", "b": "[Hex's token]"})
      refute output =~ encoded

      # Something shaped like a key holds the answer for you.
      Req.Test.stub(SavedRequest, fn conn ->
        Plug.Conn.send_resp(conn, 200, "-----BEGIN RSA PRIVATE KEY-----\nMIIE")
      end)

      asking =
        Task.async(fn ->
          mwt(context, ["call", "pr-view", "REPO=o/r", "PR=2", "--reason", "r"], stderr: false)
        end)

      card = output_card(context.username)
      assert [%{what: {:shape, "a private key"}, line: 1}] = card.run.findings
      :ok = Sandbox.decide(context.username, card.id, :send_output)
      assert {output, 0} = Task.await(asking, 10_000)
      assert output =~ "PRIVATE KEY"
    end

    test "goes through with a grant only its subgrants use, which the VM can't ask for",
         context do
      grant = github(context)

      {:ok, _} =
        Sandbox.update_grant(context.username, grant.id, %{
          "name" => "GitHub",
          "purpose" => "The GitHub API",
          "hosts" => "api.github.com, github.com",
          "reach" => "subgrants"
        })

      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      assert {output, 0} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=3", "--reason", "r"],
                 stderr: false
               )

      assert output =~ ~s("number": 7)
      assert_received {:sent, "GET", "/repos/o/r/pulls/3", "", ["Bearer " <> @value], ""}

      {output, 1} = mwt(context, ["request", grant.id, "--reason", "push"])
      assert output =~ "is only for its subgrants"

      {output, 0} = mwt(context, ["grants"])
      assert output =~ "for its subgrants only"
      assert output =~ "use: only through its subgrants"
    end

    test "a call to a credential endpoint is refused before it waits or runs", context do
      github(context)

      sub =
        pr_view(context, %{
          "name" => "add key",
          "method" => "POST",
          "url" => "https://api.github.com/user/keys",
          "params" => ""
        })

      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      test = self()

      Req.Test.stub(SavedRequest, fn conn ->
        send(test, :sent) && Plug.Conn.send_resp(conn, 201, "")
      end)

      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))

      assert {output, status} = mwt(context, ["call", sub.id, "--reason", "r"])
      assert status != 0
      assert output =~ "api.github.com is a credential endpoint"
      refute_received :sent
      assert Sandbox.snapshot(context.username).waiting == []
    end

    test "an answer other than 2xx exits 22, with its body", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context, 404)

      assert {output, 22} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=1", "--reason", "r"])

      assert output =~ "HTTP 404"
      # Always on: no card.
      assert Sandbox.snapshot(context.username).waiting == []
    end

    test "values go in encoded, and of their shape, or not at all", context do
      github(context)

      sub =
        pr_view(context, %{
          "name" => "search",
          "url" => "https://api.github.com/search/issues?q=$Q",
          "params" => "Q: text: what to look for"
        })

      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      assert {_output, 0} =
               mwt(context, ["call", "search", "Q=is:open repo:a/b&admin=1", "--reason", "r"])

      assert_received {:sent, "GET", "/search/issues", "q=is%3Aopen%20repo%3Aa%2Fb%26admin%3D1",
                       _, _}

      assert {output, 122} = mwt(context, ["call", "search", "Q=-x", "--reason", "r"])
      assert output =~ "Q isn't of its shape"
      refute_received {:sent, _, _, _, _, _}
    end

    test "puts a value in a JSON body as a value, never as JSON", context do
      github(context)

      sub =
        pr_view(context, %{
          "name" => "comment",
          "method" => "POST",
          "url" => "https://api.github.com/repos/$REPO/issues/$PR/comments",
          "body" => ~s({"body": "$TEXT"}),
          "params" => "REPO: word: r\nPR: number: p\nTEXT: text: the comment"
        })

      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context, 201)
      text = ~s(hi", "admin": true, "x": ")

      assert {_output, 0} =
               mwt(context, [
                 "call",
                 "comment",
                 "REPO=o/r",
                 "PR=3",
                 "TEXT=" <> text,
                 "--reason",
                 "r"
               ])

      assert_received {:sent, "POST", "/repos/o/r/issues/3/comments", "", _, body}
      assert Jason.decode!(body) == %{"body" => text}
    end

    test "is refused when its token grant no longer lists the host, and goes with its grant",
         context do
      grant = github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)

      # The grant edited to send its token elsewhere only.
      {:ok, _} =
        Sandbox.update_grant(context.username, grant.id, %{
          "name" => "GitHub",
          "purpose" => "The GitHub API",
          "hosts" => "github.com",
          "env" => "GH_TOKEN"
        })

      assert {output, 122} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=1", "--reason", "r"])

      assert output =~ "no longer lists the host"

      :ok = Sandbox.delete_grant(context.username, grant.id)
      refute Enum.any?(Sandbox.snapshot(context.username).grants, &(&1.id == sub.id))
    end

    test "a template that could send the token elsewhere, or let a value move it, is refused",
         context do
      github(context)

      for {attrs, field, says} <- [
            {%{"url" => "https://evil.example/x"}, :url, "sends its token only to"},
            {%{"url" => "https://$HOST/x", "params" => "HOST: word: h"}, :url, "host is fixed"},
            {%{"url" => "http://api.github.com/x", "params" => ""}, :url, "HTTPS only"},
            {%{"headers" => "Accept: application/json"}, :headers, "Say where the token goes"},
            {%{"headers" => "Authorization: Bearer {token}\nX-Pr: $PR"}, :headers, "fixed"},
            {%{"parent" => "commands"}, :parent, "under a token grant"}
          ] do
        assert {:error, errors} =
                 Sandbox.create_grant(
                   context.username,
                   Map.merge(
                     %{
                       "kind" => "request",
                       "parent" => "github",
                       "name" => "x",
                       "purpose" => "x",
                       "method" => "GET",
                       "url" => "https://api.github.com/repos/$REPO/pulls/$PR",
                       "headers" => "Authorization: Bearer {token}",
                       "params" => "REPO: word: r\nPR: number: p"
                     },
                     attrs
                   )
                 )

        assert errors[field] =~ says, inspect(attrs)
      end
    end

    test "an agent proposes one under its token grant; accepting it answers with its id",
         context do
      github(context)

      asking =
        Task.async(fn ->
          mwt(context, [
            "propose",
            "github",
            "--name",
            "pr view",
            "--for",
            "Shows a pull request",
            "--param",
            "REPO:word:the repository",
            "--param",
            "PR:number:the pull request",
            "--method",
            "GET",
            "--url",
            "https://api.github.com/repos/$REPO/pulls/$PR",
            "--reason",
            "review"
          ])
        end)

      ask = waiting(context.username, &(&1.kind == :activation))
      assert %{kind: :request, parent_name: "GitHub"} = ask.proposal

      sub = Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == ask.grant_id))
      assert %Grant{kind: :request, method: "GET", parent: "github"} = sub
      assert Grant.to_review?(sub)

      # Without --header, the headers the service expects, the token in place.
      assert {"Authorization", "Bearer {token}"} in sub.headers

      {:ok, _} = Sandbox.review(context.username, sub.id, {60, :ask})
      assert {output, 0} = Task.await(asking)
      assert output =~ "accepted it as pr-view"
      assert output =~ "mwt call pr-view REPO=… PR=…"

      # A proposal that would send the token elsewhere never waits.
      assert {output, 1} =
               mwt(context, [
                 "propose",
                 "github",
                 "--name",
                 "x",
                 "--for",
                 "y",
                 "--url",
                 "https://evil.example/collect",
                 "--reason",
                 "r"
               ])

      assert output =~ "sends its token only to"
    end
  end

  describe "editing" do
    test "keeps a subgrant's id, state and start, and checks the change as when it was added",
         context do
      {:ok, sub} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "say",
          "purpose" => "Says a word",
          "script" => ~s(echo "$WORD"),
          "params" => "WORD: word: what to say",
          "dir" => context.project
        })

      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)

      {:ok, edited} =
        Sandbox.update_grant(context.username, sub.id, %{
          "name" => "shout",
          "purpose" => "Says a word, loudly",
          "script" => ~s(echo "$WORD!"),
          "params" => "WORD: word: what to say",
          "dir" => context.project
        })

      assert %{id: "say", name: "shout", start: :auto, state: :on, parent: "commands"} = edited
      assert edited.script == ~s(echo "$WORD!")
      assert Grant.auto_approved?(edited)

      assert {"said!\n", 0} =
               mwt(context, ["call", "say", "WORD=said", "--reason", "r"], stderr: false)

      assert {:error, %{params: message}} =
               Sandbox.update_grant(context.username, sub.id, %{
                 "name" => "shout",
                 "purpose" => "x",
                 "script" => "echo fixed",
                 "params" => "WORD: word: what to say",
                 "dir" => context.project
               })

      assert message =~ "doesn't read WORD"
      built_in = Enum.find(Sandbox.snapshot(context.username).grants, &Grant.ask_to_run?/1)
      assert {:error, :built_in} = Sandbox.update_grant(context.username, built_in.id, %{})
      assert {:error, :not_found} = Sandbox.update_grant(context.username, "nope", %{})
    end

    test "a token grant keeps its placeholder and value", context do
      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "name" => "API",
          "purpose" => "An API",
          "hosts" => "api.example.com",
          "env" => "API_TOKEN",
          "source" => "stored",
          "value" => "secret"
        })

      {:ok, edited} =
        Sandbox.update_grant(context.username, grant.id, %{
          "name" => "Example API",
          "purpose" => "The example API",
          "hosts" => "api.example.com, uploads.example.com",
          "env" => "API_TOKEN, EXAMPLE_TOKEN"
        })

      assert edited.id == grant.id and edited.placeholder == grant.placeholder
      assert edited.hosts == ["api.example.com", "uploads.example.com"]
      assert edited.env == ["API_TOKEN", "EXAMPLE_TOKEN"]
      assert Sandbox.snapshot(context.username).values[grant.id] == true
    end
  end
end
