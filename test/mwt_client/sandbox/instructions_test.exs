defmodule MWTClient.Sandbox.InstructionsTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Allowance, Grant, Instructions, Param, Settings}

  doctest Instructions

  test "the block is replaced where it is, and what's around it stays" do
    once = Instructions.put_block("my own notes\n", "first")
    twice = Instructions.put_block(once, "second")

    assert twice =~ "second"
    refute twice =~ "first"
    assert String.ends_with?(twice, "my own notes\n")
    assert Instructions.put_block(twice, "second") == twice
    assert Instructions.put_block("", "only") =~ ~r/^<!-- mwt:begin.*only\n<!-- mwt:end -->\n$/s
  end

  # The VM puts the block in its own files, after every boot, with the script
  # MWT runs in it. Here the script runs on this machine, pointed at folders
  # of the test's.
  describe "the boot script" do
    setup do
      base = Path.join(System.tmp_dir!(), "boot-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)
      inbox = Path.join(base, "inbox")
      home = Path.join(base, "home")
      File.mkdir_p!(inbox)
      File.mkdir_p!(home)
      File.write!(Path.join(inbox, "agents-block.md"), Instructions.block())

      etc = Path.join(base, "etc")
      File.mkdir_p!(etc)
      cache = Path.join(base, "cache")
      File.mkdir_p!(cache)

      boot = fn args ->
        # POSIX sh, as in an image without bash. XDG_CONFIG_HOME is unset so
        # Zed's settings go under the test's home, not this machine's config
        # folder (GitHub's runners set it).
        System.cmd(
          "sh",
          [Path.join([:code.priv_dir(:mwt_client), "sandbox", "mwt-boot"]) | args],
          env: [
            {"MWT_INBOX", inbox},
            {"HOME", home},
            {"MWT_ETC", etc},
            {"MWT_CACHE", cache},
            {"XDG_CONFIG_HOME", nil}
          ],
          stderr_to_stdout: true
        )
      end

      %{
        inbox: inbox,
        home: home,
        etc: etc,
        cache: cache,
        boot: fn -> boot.([]) end,
        boot_as: boot
      }
    end

    test "puts MWT's CA in Chromium's certificate store, when the image has certutil", %{
      inbox: inbox,
      home: home,
      boot: boot
    } do
      if System.find_executable("certutil") do
        ca = MWTClient.Sandbox.CertificateAuthority.new()

        File.write!(
          Path.join(inbox, "ca.pem"),
          MWTClient.Sandbox.CertificateAuthority.pem(ca.cert)
        )

        # Twice: the second boot puts it back, once.
        assert {_, 0} = boot.()
        assert {_, 0} = boot.()

        {listed, 0} =
          System.cmd("certutil", ["-d", "sql:" <> Path.join(home, ".pki/nssdb"), "-L"])

        assert [_one] = Regex.scan(~r/MWT agent sandbox CA\s+C,,/, listed)
      end
    end

    test "gives containers MWT's CA, when the image has podman", %{
      inbox: inbox,
      etc: etc,
      boot: boot
    } do
      ca = MWTClient.Sandbox.CertificateAuthority.new()
      pem = Path.join(inbox, "ca.pem")
      File.write!(pem, MWTClient.Sandbox.CertificateAuthority.pem(ca.cert))
      conf = Path.join(etc, "containers/containers.conf.d/50-mwt.conf")

      # No podman, no file.
      assert {_, 0} = boot.()
      refute File.exists?(conf)

      File.mkdir_p!(Path.join(etc, "containers"))
      assert {_, 0} = boot.()
      {hash, 0} = System.cmd("openssl", ["x509", "-subject_hash", "-noout", "-in", pem])

      # Under the name OpenSSL looks it up by, so a build that installs
      # ca-certificates replaces nothing of it.
      text = File.read!(conf)
      assert text =~ ~s("#{pem}:/etc/ssl/certs/#{String.trim(hash)}.0:ro")
      assert text =~ ~s("#{inbox}/ca-bundle.pem:/run/mwt/ca-bundle.pem:ro")
      assert text =~ ~s("SSL_CERT_FILE=/run/mwt/ca-bundle.pem")
    end

    test "writes which VM this is, and a line for every interactive login shell", %{
      inbox: inbox,
      etc: etc,
      boot_as: boot_as
    } do
      assert {"", 0} =
               boot_as.(["3f2a9c1e", "2026-11-13T20:29:32Z", "img:2026-11-13.4", "mwt-4790"])

      assert File.read!(Path.join(etc, "mwt-vm")) ==
               "id=3f2a9c1e\ncreated=2026-11-13T20:29:32Z\nimage=img:2026-11-13.4\nname=mwt-4790\n"

      # The line asks `mwt vm`: dim when this is MWT's VM, red when it isn't.
      fake = Path.join(inbox, "bin/mwt")
      File.mkdir_p!(Path.dirname(fake))
      profile = Path.join(etc, "profile.d/mwt-vm.sh")

      shell = fn mode, status ->
        File.write!(fake, "#!/bin/sh\necho \"answer for $1\"\nexit #{status}\n")
        File.chmod!(fake, 0o755)
        # An interactive bash with no terminal complains about job control on
        # stderr; only what the line prints counts.
        System.cmd("sh", [
          "-c",
          ~S(exec bash --norc "$0" -c '. "$1"' shell "$1" 2>/dev/null),
          mode,
          profile
        ])
      end

      assert {"\e[2manswer for vm\e[0m\n", 0} = shell.("-i", 0)
      assert {"\e[1;31manswer for vm\e[0m\n", 0} = shell.("-i", 3)
      # Agents' shells aren't interactive: they hear nothing.
      assert {"", 0} = shell.("+m", 3)
    end

    test "writes no record when MWT names no VM", %{etc: etc, boot: boot} do
      assert {"", 0} = boot.()
      refute File.exists?(Path.join(etc, "mwt-vm"))
      refute File.exists?(Path.join(etc, "profile.d/mwt-vm.sh"))
    end

    test "Claude Code and Codex both get the block in Home", %{home: home, boot: boot} do
      File.mkdir_p!(Path.join(home, ".codex"))
      File.write!(Path.join(home, ".codex/AGENTS.md"), "Prefer small commits.\n")

      assert {"", 0} = boot.()

      claude = File.read!(Path.join(home, ".claude/CLAUDE.md"))
      codex = File.read!(Path.join(home, ".codex/AGENTS.md"))
      assert claude == Instructions.block()
      assert codex == Instructions.block() <> "\nPrefer small commits.\n"
    end

    test "MWT's tools are registered with Codex once, and one there already is left as it is",
         %{inbox: inbox, home: home, boot: boot} do
      fake = Path.join(inbox, "bin/mwt")
      File.mkdir_p!(Path.dirname(fake))
      File.write!(fake, "#!/bin/sh\n")
      File.chmod!(fake, 0o755)
      config = Path.join(home, ".codex/config.toml")
      File.mkdir_p!(Path.dirname(config))
      File.write!(config, "model = \"gpt-5\"\n")

      assert {"", 0} = boot.()
      assert {"", 0} = boot.()

      written = File.read!(config)
      assert written =~ ~r/\Amodel = "gpt-5"\n\n# MWT's own tools/
      assert [_] = Regex.scan(~r/^\[mcp_servers\.mwt\]$/m, written)
      assert written =~ ~s(command = "#{fake}"\nargs = ["mcp"]\n)

      # One the user changed stays theirs.
      File.write!(config, "[mcp_servers.mwt]\ncommand = \"/usr/local/bin/mine\"\n")
      assert {"", 0} = boot.()
      assert File.read!(config) == "[mcp_servers.mwt]\ncommand = \"/usr/local/bin/mine\"\n"
    end

    test "/handoff is a command for Claude Code and Codex, put back at every boot", %{
      inbox: inbox,
      home: home,
      boot: boot
    } do
      command =
        File.read!(Path.join([:code.priv_dir(:mwt_client), "sandbox", "handoff-command.md"]))

      File.write!(Path.join(inbox, "handoff-command.md"), command)

      assert {"", 0} = boot.()
      claude = Path.join(home, ".claude/commands/handoff.md")
      codex = Path.join(home, ".codex/prompts/handoff.md")
      assert File.read!(claude) == command and File.read!(codex) == command

      # Both read the description from its front matter and put the words
      # typed after /handoff where $ARGUMENTS is.
      assert command =~ ~r/\A---\ndescription: .+\nargument-hint: .+\n---\n/
      assert command =~ "mwt help handoff" and command =~ "$ARGUMENTS"

      File.write!(claude, "changed in the VM\n")
      assert {"", 0} = boot.()
      assert File.read!(claude) == command
    end

    test "a later boot replaces the block and leaves the rest", %{
      inbox: inbox,
      home: home,
      boot: boot
    } do
      assert {"", 0} = boot.()
      file = Path.join(home, ".claude/CLAUDE.md")
      File.write!(file, File.read!(file) <> "\nmy own notes\n")

      File.write!(Path.join(inbox, "agents-block.md"), Instructions.put_block("", "changed"))
      assert {"", 0} = boot.()

      assert File.read!(file) == Instructions.put_block("", "changed") <> "\nmy own notes\n"
      # The script and `put_block/2` agree on where the block goes.
      assert File.read!(file) == Instructions.put_block(File.read!(file), "changed")
    end

    test "the memo tool is copied into the VM's memory folder, which gets a memory", %{
      inbox: inbox,
      home: home,
      boot: boot
    } do
      File.mkdir_p!(Path.join(inbox, "bin"))
      memo = Path.join(inbox, "bin/memo")
      File.write!(memo, "#!/bin/sh\nmkdir -p \"$MEMORY_DIR\" && : > \"$MEMORY_DIR/LOG.txt\"\n")
      File.chmod!(memo, 0o755)

      assert {"", 0} = boot.()
      assert File.read!(Path.join(home, ".optmem/memo")) == File.read!(memo)
      assert File.regular?(Path.join(home, ".optmem/memory/LOG.txt"))
    end

    test "the adapters an older MWT's ACP shell installed go, and the rest of the cache stays",
         %{cache: cache, boot: boot} do
      adapter = Path.join(cache, "mwt-acp/claude-acp/0.112.0/claude-agent-acp")
      File.mkdir_p!(Path.dirname(adapter))
      File.write!(adapter, "old")
      File.mkdir_p!(Path.join(cache, "mise"))

      assert {"", 0} = boot.()
      refute File.exists?(Path.join(cache, "mwt-acp"))
      assert File.dir?(Path.join(cache, "mise"))
      # Gone, nothing more to do.
      assert {"", 0} = boot.()
    end

    test "the agents an older MWT put in the VM's Zed settings go, and the rest stays", %{
      home: home,
      boot: boot
    } do
      # No settings: none are made.
      assert {"", 0} = boot.()
      refute File.exists?(Path.join(home, ".config/zed/settings.json"))

      settings = Path.join(home, ".config/zed/settings.json")
      File.mkdir_p!(Path.dirname(settings))

      File.write!(
        settings,
        Jason.encode!(%{
          "theme" => "One Dark",
          "agent_servers" => %{
            "Mine" => %{"type" => "custom", "command" => "/usr/local/bin/mwt-acp-not"},
            "Claude (MWT)" => %{"type" => "custom", "command" => "/mnt/mwt/bin/mwt-acp"},
            "Codex (MWT)" => %{"type" => "custom", "command" => "/mnt/mwt/bin/mwt-acp"}
          }
        })
      )

      assert {"", 0} = boot.()

      assert Jason.decode!(File.read!(settings)) == %{
               "theme" => "One Dark",
               "agent_servers" => %{
                 "Mine" => %{"type" => "custom", "command" => "/usr/local/bin/mwt-acp-not"}
               }
             }

      # One it can't read as JSON is left as it is, and the boot says so.
      broken = ~s|{"agent_servers": {"Claude (MWT)": {"command": "/mnt/mwt/bin/mwt-acp"},},}|
      File.write!(settings, broken)
      assert {output, 1} = boot.()
      assert output =~ "could not take MWT's old agents out of Zed's settings"
      assert File.read!(settings) == broken
    end
  end

  test "the standing text forbids the usual login steps and says what MWT's refusals mean" do
    text = Instructions.text()
    assert text =~ "gh auth login"
    assert text =~ "/mnt/mwt/grants.md"
    assert text =~ "mwt request GRANT_ID --reason"
    assert text =~ "mwt request --need"
    assert text =~ "~/.optmem/memo wake"
    assert text =~ "mwt_denied_by_user"
    assert text =~ "mwt_isolated"
    # Every code is explained where it is looked up.
    assert Instructions.guides()["access"] =~ "mwt_grant_off"
  end

  test "the standing text holds what every task needs, and sends to a guide for the rest" do
    text = Instructions.text()
    guides = Instructions.guides()

    assert Map.keys(guides) |> Enum.sort() ==
             ~w(access handoff projects propose resources run workspace)

    # Every guide is named in the text, or in another guide, so an agent
    # finds it; and every guide named exists.
    named = Regex.scan(~r/mwt help ([a-z-]+)/, Enum.join([text | Map.values(guides)], "\n"))

    for [_, topic] <- named,
        topic != "TOPIC",
        do: assert(Map.has_key?(guides, topic), "mwt help #{topic} names no guide")

    for topic <- Map.keys(guides),
        do: assert(Enum.any?(named, &(&1 == ["mwt help " <> topic, topic])), "#{topic} unnamed")

    # The rules every task needs stay in the text itself.
    assert text =~ "Take your slot first, before anything else"
    assert text =~ "Never commit unless the user says so"
    assert text =~ "Hand off only when the user asks"
    assert text =~ "Conventional Commit"
  end

  # What agents read has a budget, in bytes. Claude Code and Codex load the
  # standing text, the user's way of working and the project's AGENTS.md
  # whole into every session, subagent and approval review, and Codex warns
  # once they pass 32 KiB together. A change that needs more room makes it
  # first, by moving what only some tasks need into a guide or tightening
  # what is there. Raising a budget is the user's call.
  @budgets %{
    "priv/sandbox/agents.md" => 12_288,
    "priv/sandbox/way-of-working-example.md" => 9_216,
    "AGENTS.md" => 8_192
  }
  @guide_budget 8_192
  @codex_warns_at 32_768

  test "what agents read in every session keeps within its budget" do
    for {file, budget} <- @budgets do
      size = byte_size(File.read!(Path.join(File.cwd!(), file)))

      assert size <= budget,
             "#{file} is #{size} bytes, over its budget of #{budget}. Agents read it in " <>
               "every session: make room first (move what only some tasks need into a " <>
               "guide, or tighten what is there) rather than raise the budget, which is " <>
               "the user's call."
    end

    # Together, as Codex counts them in a project whose user started from
    # MWT's example: under its warning, whatever the budgets add up to.
    total =
      byte_size(Instructions.block(way_of_working: Instructions.way_of_working_example())) +
        byte_size(File.read!(Path.join(File.cwd!(), "AGENTS.md")))

    assert total < @codex_warns_at,
           "What agents read in every session is #{total} bytes together, past the " <>
             "#{@codex_warns_at} at which Codex warns: make room before adding."
  end

  test "each guide keeps within its budget" do
    for {topic, text} <- Instructions.guides() do
      assert byte_size(text) <= @guide_budget,
             "mwt help #{topic} is #{byte_size(text)} bytes, over the #{@guide_budget} a " <>
               "guide may take: it is read whole when needed, so split it by situation or " <>
               "tighten it, rather than raise the budget, which is the user's call."
    end
  end

  test "the /handoff command follows the handoff guide" do
    command =
      File.read!(Path.join([:code.priv_dir(:mwt_client), "sandbox", "handoff-command.md"]))

    assert command =~ "mwt help handoff"
    assert command =~ "$ARGUMENTS"
    assert Instructions.guides()["handoff"] =~ "mwt handoff --title"
  end

  test "the user's way of working follows the instructions, under MWT's heading, when written" do
    agents = File.read!(Path.join([:code.priv_dir(:mwt_client), "sandbox", "agents.md"]))

    # agents.md says how to work in the VM; the way of working is the user's.
    refute agents =~ "way of working"

    assert Instructions.text() == agents
    assert Instructions.text(way_of_working: "") == agents
    assert Instructions.text(way_of_working: "  \n") == agents

    assert Instructions.text(way_of_working: "Keep answers short.\n") ==
             agents <>
               "\n## The user's way of working\n\n" <>
               "The user wrote this for the agents in this VM: how they like to work with\n" <>
               "you, their own taste rather than a rule of the VM.\n\n" <>
               "Keep answers short.\n"

    block = Instructions.block(way_of_working: "Keep answers short.")
    assert block =~ ~r/Memory.*## The user's way of working.*short\.\n<!-- mwt:end -->\n\z/s
  end

  test "MWT's example of a way of working fits under that heading" do
    example = Instructions.way_of_working_example()

    assert example =~ ~r/\A### The main operation, first\n/
    assert example =~ "\n### Decisions: which to bring to the user\n"
    assert example =~ "\n### Building blocks\n"
    assert example =~ "**A component per job the operation needs, named for that job.**"
    refute example =~ ~r/^## /m

    assert {:ok, %{way_of_working: _}} =
             Settings.cast(%Settings{}, %{"way_of_working" => example})
  end

  test "the grants list says what each is for and how to use it, never values" do
    github = %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      purpose: "Push to\nmy repos",
      state: :on,
      expires_at: ~U[2026-11-12 13:00:00Z],
      placeholder: "ghp_placeholder",
      env: ["GH_TOKEN"],
      git: true,
      hosts: ["api.github.com", "github.com"]
    }

    vpn = %Grant{
      id: "vpn",
      name: "VPN",
      kind: :network,
      purpose: "Grafana",
      destinations: ["10.0.0.0/8:443"],
      allowances: [%Allowance{id: "a", pattern: :all}],
      state: :on
    }

    text = Instructions.grants([github, vpn], ~U[2026-11-12 12:00:00Z])
    assert text =~ "## GitHub"

    assert text =~
             "id: `github` · open use of the credential `github` · on until 13:00 UTC (60 min left)"

    assert text =~ "for: Push to my repos"
    assert text =~ "$GH_TOKEN, /mnt/mwt/tokens/github"
    assert text =~ "only to api.github.com, github.com"
    assert text =~ "git over HTTPS to api.github.com, github.com"
    assert text =~ "each request waits for the user's approval"
    assert text =~ "id: `vpn` · open use of the network `vpn`"
    assert text =~ "connect directly to 10.0.0.0/8:443"
    assert text =~ "each use goes through without asking"
    refute text =~ "ghp_placeholder"
    assert Instructions.grants([], ~U[2026-11-12 12:00:00Z]) =~ "No grants yet."
  end

  test "actions are listed under their resource, with how to call them; a command you write asks" do
    saved =
      for name <- ~w(pods logs) do
        %Grant{
          id: name,
          name: name,
          kind: :command,
          purpose: "Show #{name}",
          script: "kubectl get #{name} -n \"$NAMESPACE\"",
          dir: "/home/me",
          params: [
            %Param{
              name: "NAMESPACE",
              about: "the namespace",
              schema: %{"type" => "string", "enum" => ["web", "jobs"]}
            }
          ],
          state: :on
        }
      end

    github = %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      purpose: "The API",
      credential: "github",
      hosts: ["api.github.com"]
    }

    view = %Grant{
      id: "gh-repo",
      name: "Repository",
      kind: :request,
      purpose: "View a repository",
      credential: "github",
      method: "GET",
      url: "https://api.github.com/repos/$REPO",
      params: [
        %Param{
          name: "REPO",
          about: "the repository",
          schema: %{"type" => "string", "format" => "word"}
        }
      ]
    }

    text = Instructions.grants([view | saved] ++ [github], ~U[2026-11-12 12:00:00Z])
    # A command the agent writes asks every time: kept small.
    assert text =~ "while Commands agents write is on, you may ask to"
    assert text =~ "send the smallest command that gets what"
    assert text =~ "mwt help run"
    assert text =~ ~s(mwt call ID NAME=value --reason "why now")

    # Under their resource: how to call each, its state, what it is for,
    # and each parameter with its shape.
    assert text =~ "Saved commands, fixed calls over host commands"

    assert text =~ """
             - `mwt call pods NAMESPACE=…` · on until turned off · Show pods
               - NAMESPACE is one of: web, jobs. It is: the namespace
             - `mwt call logs NAMESPACE=…` · on until turned off · Show logs
           """

    # A fixed request sits under its credential, after the grants over it.
    [_before, credential] = String.split(text, "## GitHub", parts: 2)
    assert credential =~ "Fixed requests over the credential `github`"
    assert credential =~ "`mwt call gh-repo REPO=…` · off"

    # What it is for, not its script.
    refute text =~ "## pods"
    refute text =~ "kubectl get pods"
  end

  test "a fixed call's line says how open it is, unless it is narrow" do
    open = %Grant{
      id: "kubectl-any",
      name: "kubectl any",
      kind: :command,
      purpose: "Runs kubectl",
      script: "kubectl $ARGS",
      dir: "/home/me",
      params: [%Param{name: "ARGS", about: "the arguments", schema: %{"type" => "string"}}],
      state: :on
    }

    narrow = %Grant{
      open
      | id: "pods",
        name: "pods",
        purpose: "Show pods",
        script: ~s(kubectl get pods -n "$NS"),
        params: [
          %Param{name: "NS", about: "the namespace", schema: %{"enum" => ["web", "jobs"]}}
        ]
    }

    text = Instructions.grants([open, narrow], ~U[2026-11-12 12:00:00Z])
    assert text =~ "· Runs kubectl · How open: Open."
    assert text =~ "· Show pods\n"
  end

  test "the guides say to keep commands small and to transform in the VM" do
    guides = Instructions.guides()
    assert guides["run"] =~ "Bring the raw output back and do the rest here in the VM"
    # Actions come first: called by id, proposed with their design in mind.
    assert Instructions.text() =~ "mwt call gh-repo-view REPO_NAME=oliveigah/klife"
    assert Instructions.text() =~ ~r/You send an id and values,\s+never a command/
    assert guides["propose"] =~ "mwt propose commands"
    assert guides["propose"] =~ "The narrowest shape that works"
  end
end
