defmodule MWTClient.Sandbox.HostCommandChannelTest do
  @moduledoc """
  Host commands end to end: the `mwt` command in the VM (here, with a fake
  socat), the channel, the server's approval, the run on this machine, and
  what the agent hears back. Subgrants have subgrant_channel_test.exs, and
  what agents propose proposal_channel_test.exs.
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox

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
end
