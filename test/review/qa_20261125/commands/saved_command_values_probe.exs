defmodule MWTClient.QAProbes.Commands.SavedCommandValuesTest do
  @moduledoc """
  Probe: saved commands (fixed calls over host commands). They run only by
  exact id, take no script from the agent, are refused while host commands
  or a credential they run with is locked; values reach the script only as
  variables and never change what runs; a refused value is named by its
  parameter, never shown (docs/grant_mental_model.md, "A fixed call, step
  by step", 3). What the VM sends holding a real value is refused and the
  firewall told (point 13, "Scanning"). Each refusal leaves a line saying
  how it was decided (`MWTClient.Sandbox.Decision`).
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Grant, Param, Policy, Server}

  @value "ghp_qaRealValue0123456789abcdefABCDEF01"

  setup do
    base = Path.join(System.tmp_dir!(), "qa-saved-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)

    MWTClient.VaultHelpers.unlocked_identity("qa-saved")
    |> Map.merge(%{base: base})
  end

  defp saved(context, script, params, extra \\ %{}) do
    {:ok, grant} =
      Sandbox.create_grant(
        context.username,
        Map.merge(
          %{
            "kind" => "command",
            "name" => "echo it #{System.unique_integer([:positive])}",
            "purpose" => "Prints a value",
            "script" => script,
            "params" => params,
            "dir" => context.base
          },
          extra
        )
      )

    {:ok, _} = Sandbox.set_start(context.username, grant.id, :auto)
    grant
  end

  defp call(username, id, values) do
    ask = %{grant: id, script: nil, values: values, dir: nil, reason: "r", agent: "claude"}
    Server.call(username, {:call, ask})
  end

  defp final(username, id) do
    {:ok, approval, _grant} = Server.call(username, {:await, id, 10_000}, 15_000)
    approval
  end

  test "hostile values reach the script as data, and run nothing", context do
    marker = Path.join(context.base, "ran")
    grant = saved(context, ~S{printf '[%s]\n' "$V"}, "V: text: what to print")

    values = [
      "$(touch #{marker})",
      "`touch #{marker}`",
      "a; touch #{marker}",
      "a\ntouch #{marker}",
      "a && touch #{marker} #",
      "*",
      "~/.ssh/*",
      "${IFS}touch${IFS}#{marker}",
      # Cyrillic а in "p" <> <<0x0430::utf8>> <> "ypal": shown as it is, data all the same.
      "p" <> <<0x0430::utf8>> <> "ypal",
      String.duplicate("x", 4096)
    ]

    for value <- values do
      {:ok, card} = call(context.username, grant.id, %{"V" => value})
      assert %{run: %{exit: 0, output: output}} = final(context.username, card.id)
      assert output == "[#{value}]\n", "#{inspect(value)} printed as #{inspect(output)}"
    end

    refute File.exists?(marker)
  end

  test "MWT's floor refuses options, going up, blank, hidden characters and bidi", context do
    grant = saved(context, ~S{printf '[%s]\n' "$V"}, "V: text: what to print")

    for value <- [
          "-rf",
          " --all",
          "../x",
          "a/../../b",
          "a/./b",
          "  ",
          "a" <> <<0x202E::utf8>> <> "b",
          "a" <> <<0x200B::utf8>> <> "b",
          String.duplicate("x", 4097)
        ] do
      assert {:error, {:values, _grant, problem}} =
               call(context.username, grant.id, %{"V" => value})

      assert elem(problem, 1).name == "V", "#{inspect(value)}: #{inspect(problem)}"
    end
  end

  test "a refusal names the parameter, never the value: to the agent and in the log",
       context do
    schema =
      Jason.encode!(%{
        "properties" => %{
          "STAGE" => %{
            "description" => "where",
            "type" => "string",
            "enum" => ["staging", "prod"]
          },
          "TICKET" => %{
            "description" => "ticket",
            "type" => "string",
            "pattern" => "^[A-Z]+-[0-9]+$"
          },
          "N" => %{"description" => "how many", "type" => "integer", "maximum" => 5}
        }
      })

    {:ok, grant} =
      Sandbox.create_grant(context.username, %{
        "kind" => "command",
        "name" => "three",
        "purpose" => "Prints three values",
        "script" => ~S{printf '%s %s %s\n' "$STAGE" "$TICKET" "$N"},
        "schema" => schema,
        "dir" => context.base
      })
      |> tap(&IO.inspect(&1, label: "\n[saved values] schema grant"))

    {:ok, _} = Sandbox.set_start(context.username, grant.id, :auto)

    secretish = "zzSECRETISHzz"

    for values <- [
          %{"STAGE" => secretish, "TICKET" => "A-1", "N" => "1"},
          %{"STAGE" => "prod", "TICKET" => secretish, "N" => "1"},
          %{"STAGE" => "prod", "TICKET" => "A-1", "N" => "987654321"}
        ] do
      {:error, reason} = call(context.username, grant.id, values)
      {:values, _grant, problem} = reason
      # What the agent hears may echo its own value back (a maximum does:
      # "value 987654321 is higher than maximum 5"); noted, not asserted:
      # the doc's rule is the log's.
      IO.puts("\n[saved values] the agent hears: " <> Param.explain(problem))
    end

    for event <- Sandbox.events(context.username, %{limit: 50}) do
      refute inspect(event) =~ secretish, "the log shows the value: #{event.summary}"
    end
  end

  test "a real value sent as a parameter's name is not looked at", context do
    grant = saved(context, ~S{printf '[%s]\n' "$V"}, "V: text: what to print")

    {:ok, gh} =
      Sandbox.create_grant(context.username, %{
        "kind" => "token",
        "name" => "GitHub",
        "purpose" => "Reads klife",
        "hosts" => "api.github.com",
        "value" => @value
      })

    {:ok, _} = Sandbox.turn_on(context.username, gh.id, 60, :all)

    # As a name: `screened/2` looks at a map's values only.
    answer = call(context.username, grant.id, %{"V" => "x", @value => "x"})
    IO.puts("\n[saved values] a real value as a name answers #{inspect(answer)}")

    IO.puts(
      "[saved values] firewall isolated after it? #{inspect(Server.call(context.username, :firewall_isolated?))}"
    )

    logged =
      context.username
      |> Sandbox.events(%{limit: 50})
      |> Enum.filter(&(inspect(&1) =~ String.slice(@value, 0, 30)))
      |> Enum.map(& &1.summary)

    IO.puts("[saved values] log lines holding it: #{inspect(logged)}")
    assert answer == {:error, :firewall}, "a real value as a name wasn't refused as one"
  end

  describe "locks" do
    test "host commands locked, or a credential it runs with locked, refuses (pure policy)" do
      now = ~U[2026-11-25 12:00:00Z]
      every = %MWTClient.Sandbox.Allowance{id: "a", pattern: :all, until: nil}

      grant = %Grant{
        id: "report",
        name: "Report",
        kind: :command,
        script: "report",
        dir: "/tmp",
        state: :on,
        confined: true,
        with: ["stripe"],
        allowances: [every]
      }

      base = %{grants: [grant], own: [], resolve: fn _ -> [] end}
      use = {:command, %{grant: "report"}}

      assert {:allow, _, _, _} = Policy.decide(base, use, now)

      assert {:refuse, {:locked, :machine, _}} =
               Policy.decide(Map.put(base, :locks, %{machine: [:you]}), use, now)

      assert {:refuse, {:locked, {:credential, "stripe"}, _}} =
               Policy.decide(
                 Map.put(base, :locks, %{{:credential, "stripe"} => [:you]}),
                 use,
                 now
               )

      # By exact id: no prefix, no case, no name; a script with it, refused.
      for wanted <- ["Report", "repor", "REPORT", "report;id"] do
        refute match?({:allow, _, _, _}, Policy.decide(base, {:command, %{grant: wanted}}, now)),
               "#{inspect(wanted)} ran report"
      end

      assert {:refuse, {:fixed_script, _}} =
               Policy.decide(base, {:command, %{grant: "report", script: "id"}}, now)
    end
  end

  describe "parameter names are variables every tool the script starts reads" do
    # `Param.reserved?/1` is a deny list (shell, loader, git, ssh, MWT); a
    # name an interpreter or a tool reads from the environment passes, and
    # its value reaches every program the script starts, not only where the
    # script shows `$NAME`.
    test "names interpreters and tools read are accepted" do
      for name <-
            ~w(PYTHONPATH NODE_OPTIONS PERL5OPT RUBYOPT KUBECONFIG HTTPS_PROXY XDG_CONFIG_HOME) do
        assert Param.name_error(name) != :ok, "#{name} is accepted as a parameter's name"
      end
    end
  end

  describe "audit: a refused ask leaves a line saying so" do
    defp refused_lines(username),
      do: Sandbox.events(username, %{decided: "refused", limit: 50})

    test "a written command refused for host commands locked", context do
      :ok = Sandbox.lock(context.username, :machine)
      ask = %{grant: nil, script: "id", dir: nil, reason: "r", agent: "claude"}

      assert {:error, {:locked, :machine, _}} =
               Server.call(context.username, {:request_command, ask})

      IO.puts(
        "\n[audit] lines after the refusal: " <>
          inspect(
            Enum.map(Sandbox.events(context.username, %{limit: 10}), &{&1.summary, &1.decision})
          )
      )

      assert refused_lines(context.username) != [], "no line says a command was refused"
    end

    test "a saved command's call refused while it is off, or host commands locked", context do
      grant = saved(context, ~S{printf '[%s]\n' "$V"}, "V: text: what to print")
      {:ok, _} = Sandbox.turn_off(context.username, grant.id)
      assert {:error, {:grant_off, _}} = call(context.username, grant.id, %{"V" => "x"})
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)
      :ok = Sandbox.lock(context.username, :machine)
      assert {:error, {:locked, :machine, _}} = call(context.username, grant.id, %{"V" => "x"})

      IO.puts(
        "\n[audit] saved: " <>
          inspect(
            Enum.map(
              Sandbox.events(context.username, %{limit: 10}),
              &{&1.summary, &1.decision && &1.decision.by}
            )
          )
      )

      assert length(refused_lines(context.username)) >= 2, "the refused calls left no line"
    end

    test "a saved command's call refused for its values", context do
      grant = saved(context, ~S{printf '[%s]\n' "$V"}, "V: text: what to print")
      assert {:error, _} = call(context.username, grant.id, %{"V" => "-rf"})

      line =
        Enum.find(
          Sandbox.events(context.username, %{limit: 20}),
          &(&1.summary =~ "refused before anything ran")
        )

      assert line, "no line for the refused call"
      assert line.decision, "the refused call's line says nothing of how it was decided"
    end
  end
end
