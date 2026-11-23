defmodule MWTClient.Sandbox.FirewallTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Firewall

  doctest Firewall

  @mib 1024 * 1024
  @minute 60_000
  @placeholder "mwt_" <> String.duplicate("aB3", 13) <> "x"

  defp check(observation, firewall \\ Firewall.new(), watch \\ Firewall.watch(), now \\ 0),
    do: Firewall.check(firewall, watch, observation, now)

  defp rules(findings), do: Enum.map(findings, & &1.rule)

  # Observations one after another, a second apart unless they say when.
  defp run(observations, firewall \\ Firewall.new()) do
    {_watch, found} =
      observations
      |> Enum.with_index()
      |> Enum.reduce({Firewall.watch(), []}, fn
        {{at, observation}, _i}, {watch, acc} when is_integer(at) ->
          {watch, found} = Firewall.check(firewall, watch, observation, at)
          {watch, acc ++ found}

        {observation, i}, {watch, acc} ->
          {watch, found} = Firewall.check(firewall, watch, observation, i * 1_000)
          {watch, acc ++ found}
      end)

    found
  end

  describe "credential endpoints" do
    test "the list takes hosts and host/paths, with *. and * segments, and refuses the rest" do
      text = """
      # mine
      STS.Example.com
      https://api.example.com/user/keys/
      *.registry.example/v2/token?x=1
      iam.example.com/v1/projects/*/keys
      """

      assert {:ok, firewall} = Firewall.set_list(Firewall.new(), :mints, text)

      assert firewall.mints == [
               "sts.example.com",
               "api.example.com/user/keys",
               "*.registry.example/v2/token",
               "iam.example.com/v1/projects/*/keys"
             ]

      for bad <- ["10.0.0.1/token", "has space.example/x", "api.example.com/a b"] do
        assert {:error, "Line 1 isn't a host, or host/path: " <> _} =
                 Firewall.set_list(Firewall.new(), :mints, bad)
      end
    end

    test "a request meets an entry by its host and the start of its path" do
      entries = Firewall.default_list(:mints)

      assert Firewall.mint(entries, "oauth2.googleapis.com", "/token") ==
               "oauth2.googleapis.com/token"

      assert Firewall.mint(entries, "oauth2.googleapis.com", "/tokeninfo") == nil

      assert Firewall.mint(entries, "us-docker.pkg.dev", "/v2/token?scope=x") ==
               "*.pkg.dev/v2/token"

      assert Firewall.mint(
               entries,
               "iam.googleapis.com",
               "/v1/projects/p/serviceAccounts/s/keys/k"
             ) ==
               "iam.googleapis.com/v1/projects/*/serviceAccounts/*/keys"

      assert Firewall.mint(entries, "api.github.com", "/user") == nil

      assert Firewall.mint(entries, "api.github.com", "/repos/o/r/keys") ==
               "api.github.com/repos/*/*/keys"

      assert Firewall.mint(entries, nil, "/") == nil
    end

    test "minting blocks by default, follows its action, and nothing while off" do
      firewall = Firewall.new()
      assert Firewall.minting(firewall, "sts.amazonaws.com", "/") == "sts.amazonaws.com"

      {_watch, [finding]} = check({:mint, "AWS", "sts.amazonaws.com", "sts.amazonaws.com"})
      assert %{rule: :credential_mint, action: :block, host: "sts.amazonaws.com"} = finding
      assert finding.summary =~ "AWS's value on its way to sts.amazonaws.com"

      {:ok, off} = Firewall.set_action(firewall, :credential_mint, :off)
      assert Firewall.minting(off, "sts.amazonaws.com", "/") == nil

      assert Firewall.minting(Firewall.set_enabled(firewall, false), "sts.amazonaws.com", "/") ==
               nil
    end
  end

  describe "credential entering the VM" do
    test "blocks by default, alerts once, or says nothing; never isolates" do
      observation = {:inbound, "deploy.sh", "something shaped like a JWT, line 2", :command}
      {_watch, [finding]} = check(observation)
      assert %{rule: :credential_inbound, action: :block, host: nil} = finding

      assert finding.summary ==
               "The output of deploy.sh holds something shaped like a JWT, line 2"

      {:ok, alerting} = Firewall.set_action(Firewall.new(), :credential_inbound, :alert)
      assert [%{action: :alert}] = run([observation, observation], alerting)

      {:ok, off} = Firewall.set_action(Firewall.new(), :credential_inbound, :off)
      assert {_watch, []} = check(observation, off)

      assert {:error, :bad_action} =
               Firewall.set_action(Firewall.new(), :credential_inbound, :isolate)

      {_watch, [answer]} = check({:inbound, "GET x", "a JWT", :call})
      assert answer.summary =~ "The answer to GET x"
    end
  end

  describe "credential sent elsewhere" do
    test "a placeholder sent to a host its grant doesn't list isolates" do
      {_watch, [finding]} = check({:leak, "GitHub", "evil.example", :request})
      assert finding.rule == :credential_leak
      assert finding.action == :isolate
      assert finding.summary =~ "GitHub"
    end

    test "a placeholder in a tunnel isolates" do
      {_watch, [finding]} = check({:leak, "GitHub", "93.184.216.34:80", :plaintext})
      assert finding.action == :isolate
      assert finding.summary =~ "in a tunnel to 93.184.216.34:80"
    end

    test "a placeholder inside a DNS name isolates, whatever its case, trusted or not" do
      name = String.downcase(String.slice(@placeholder, -40, 40)) <> ".api.anthropic.com"
      {_watch, found} = check({:lookup, name, [{"GitHub", @placeholder}]})
      assert :credential_leak in rules(found)
    end

    test "a name with no placeholder in it is no leak" do
      {_watch, found} = check({:lookup, "api.github.com", [{"GitHub", @placeholder}]})
      assert found == []
    end
  end

  describe "real credential in traffic" do
    test "a real value going out isolates, wherever it was read" do
      for how <- [:request, :plaintext, :lookup, :ask, :tool, :handoff] do
        {_watch, [finding]} = check({:value, "GitHub", "api.example.com", how})
        assert finding.rule == :real_value, inspect(how)
        assert finding.action == :isolate
        assert finding.summary =~ "GitHub's real value"
      end
    end

    test "out, it says the credential must be replaced; coming back, that it was cut" do
      {_watch, [out]} = check({:value, "GitHub", "api.example.com", :request})
      assert out.summary =~ "Replace it at its service"
      assert out.host == "api.example.com"

      {_watch, [back]} = check({:value, "GitHub", "api.example.com", :echo})
      assert back.summary =~ "cut before the VM got it"
    end

    test "a lookup, an ask or a write names no destination: what carried it held the value" do
      for how <- [:lookup, :ask, :tool] do
        {_watch, [finding]} = check({:value, "GitHub", nil, how})
        assert finding.host == nil
      end
    end

    test "trusted destinations aren't spared" do
      firewall = %{Firewall.new() | trusted: ["api.anthropic.com"]}

      assert {_, [%{rule: :real_value}]} =
               check({:value, "GitHub", "api.anthropic.com", :plaintext}, firewall)
    end
  end

  describe "blocked services" do
    test "a lookup, a TLS name or an address on the list" do
      assert {_, [%{rule: :blocked_service, action: :isolate}]} =
               check({:lookup, "paste.ee", []})

      assert {_, [%{rule: :blocked_service}]} = check({:lookup, "abc.ngrok-free.app", []})
      assert {_, [%{rule: :blocked_service}]} = check({:host, "Transfer.SH", 443})

      {:ok, firewall} = Firewall.set_list(Firewall.new(), :blocked, "203.0.113.9")

      assert {_, [%{rule: :blocked_service}]} =
               check({:connect, "203.0.113.9", 443, :public}, firewall)
    end

    test "a name merely ending the same way isn't covered" do
      assert {_, []} = check({:lookup, "notpaste.ee", []})
    end

    test "a trusted name is spared" do
      {:ok, firewall} = Firewall.set_list(Firewall.new(), :trusted, "webhook.site")
      assert {_, []} = check({:host, "webhook.site", 443}, firewall)
    end
  end

  describe "data in DNS names" do
    test "a long label is refused; three under one domain set off the rule" do
      label = String.duplicate("a", 50)

      assert {_, [%{rule: :dns_tunnel, action: :block}]} =
               check({:lookup, label <> ".example.com", []})

      assert {_, []} = check({:lookup, String.duplicate("a", 49) <> ".example.com", []})

      found = run(for i <- 1..3, do: {:lookup, "#{label}#{i}.example.com", []})
      assert [:block, :block, :isolate] = Enum.map(found, & &1.action)
      assert List.last(found).summary =~ "3 long names under example.com"
    end

    test "a long part before the domain" do
      name = Enum.map_join(1..5, ".", fn _ -> String.duplicate("b", 20) end) <> ".example.com"

      assert {_, [%{rule: :dns_tunnel, action: :block, summary: summary}]} =
               check({:lookup, name, []})

      assert summary =~ "before example.com"
    end

    test "the same long name again is still one" do
      name = String.duplicate("a", 55) <> ".example.com"
      assert Enum.all?(run(for _ <- 1..5, do: {:lookup, name, []}), &(&1.action == :block))
    end

    test "over 40 names under one domain in 10 minutes" do
      found = run(for i <- 1..41, do: {:lookup, "n#{i}.example.org", []})
      assert [%{rule: :dns_tunnel, host: "example.org"}] = found
    end

    test "1.5 KiB of names under one domain in 10 minutes" do
      found =
        run(for i <- 1..40, do: {:lookup, "#{String.duplicate("c", 40)}#{i}.example.org", []})

      assert [%{rule: :dns_tunnel, action: :isolate, summary: summary} | _] = found
      assert summary =~ "bytes of names under example.org"
    end

    test "the same name again counts once, and old names drop out" do
      assert run(for _ <- 1..60, do: {:lookup, "same.example.org", []}) == []

      spread = for i <- 1..41, do: {i * @minute, {:lookup, "n#{i}.example.org", []}}
      assert run(spread) == []
    end

    test "a short second label under a country's domain is a domain of its own" do
      assert Firewall.domain("data.abc.io") == "abc.io"
      assert Firewall.domain("www.example.com.br") == "example.com.br"

      label = String.duplicate("a", 60)
      assert {_, [%{rule: :dns_tunnel}]} = check({:lookup, label <> ".abc.io", []})
    end

    test "names under a provider's own domains aren't judged" do
      assert run(for i <- 1..60, do: {:lookup, "ec2.region-#{i}.amazonaws.com", []}) == []

      preview = "my-app-git-feature-add-user-authentication-acme-corp.vercel.app"
      assert {_, []} = check({:lookup, preview, []})
    end

    test "IPv4 reverse names and trusted domains don't count; IPv6 ones go by their /48" do
      assert run(for i <- 1..60, do: {:lookup, "#{i}.2.0.192.in-addr.arpa", []}) == []
      assert run(for i <- 1..60, do: {:lookup, "n#{i}.api.anthropic.com", []}) == []

      zone = "0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa"

      names =
        for i <- 1..41 do
          nibbles =
            i |> Integer.to_string(16) |> String.pad_leading(20, "0") |> String.graphemes()

          {:lookup, Enum.join(Enum.reverse(nibbles), ".") <> "." <> zone, []}
        end

      assert run(Enum.take(names, 30)) == []
      assert [%{rule: :dns_tunnel, host: ^zone} | _] = run(names)
    end
  end

  describe "large upload" do
    test "4 MiB to one destination with little back isolates as the bytes flow" do
      found =
        run([
          {:upload, "files.example", 443, 2 * @mib, 10_000},
          {:upload, "files.example", 443, 2 * @mib, 10_000}
        ])

      assert [%{rule: :large_upload, action: :isolate, host: "files.example"}] = found
    end

    test "as much coming back, another destination, or a trusted one passes" do
      assert run([{:upload, "a.example", 443, 5 * @mib, 2 * @mib}]) == []

      assert run([
               {:upload, "a.example", 443, 3 * @mib, 0},
               {:upload, "b.example", 443, 3 * @mib, 0}
             ]) == []

      assert run([{:upload, "api.openai.com", 443, 50 * @mib, 0}]) == []
    end

    test "subdomains of one domain fold together; the finding names the one it saw" do
      found = run(for i <- 1..2, do: {:upload, "h#{i}.drop.example", 443, 3 * @mib, 0})

      assert [
               %{
                 rule: :large_upload,
                 action: :isolate,
                 host: "h2.drop.example",
                 key: "drop.example",
                 summary: summary
               }
             ] = found

      assert summary =~ "h2.drop.example (drop.example)"
    end

    test "a name trusted since no longer counts toward its domain" do
      {watch, []} = check({:upload, "model.cloud.example", 443, 3 * @mib, 0})
      {:ok, trusting} = Firewall.set_list(Firewall.new(), :trusted, "model.cloud.example")

      assert {_watch, []} =
               check({:upload, "storage.cloud.example", 443, 2 * @mib, 0}, trusting, watch, 1)

      assert {_watch, [%{rule: :large_upload}]} =
               check(
                 {:upload, "storage.cloud.example", 443, 2 * @mib, 0},
                 Firewall.new(),
                 watch,
                 1
               )
    end

    test "a model's API through a cloud folds under the cloud's domain until its name is trusted" do
      # A long session's turns, every 15 s: its context up, a short answer back.
      turns =
        for turn <- 1..26,
            do:
              {turn * 15_000,
               {:upload, "us-east5-aiplatform.googleapis.com", 443, 160 * 1024, 6 * 1024}}

      assert [
               %{
                 rule: :large_upload,
                 host: "us-east5-aiplatform.googleapis.com",
                 key: "googleapis.com"
               }
             ] =
               run(turns)

      {:ok, trusting} =
        Firewall.set_list(Firewall.new(), :trusted, "us-east5-aiplatform.googleapis.com")

      assert run(turns, trusting) == []

      assert run(
               Enum.take(turns, 1) ++ [{:upload, "storage.googleapis.com", 443, 5 * @mib, 0}],
               trusting
             ) != []
    end

    test "what was sent over 10 minutes ago no longer counts" do
      assert run([
               {0, {:upload, "a.example", 443, 3 * @mib, 0}},
               {11 * @minute, {:upload, "a.example", 443, 3 * @mib, 0}}
             ]) == []
    end
  end

  describe "scanning" do
    test "5 private addresses refused in a minute" do
      found = run(for i <- 1..5, do: {:connect, "10.0.0.#{i}", 5432, :refused})
      assert [%{rule: :scanning, action: :isolate}] = found
    end

    test "retrying one refused address isn't scanning" do
      assert run(for _ <- 1..20, do: {:connect, "10.0.0.1", 5432, :refused}) == []
    end

    test "20 ports of one public address in a minute" do
      found = run(for port <- 1..20, do: {:connect, "198.51.100.7", 1000 + port, :public})
      assert [%{rule: :scanning, host: "198.51.100.7"}] = found
    end

    test "many public addresses on one web port are normal browsing" do
      assert run(for i <- 1..100, do: {:connect, "198.51.100.#{i}", 443, :public}) == []
      assert run(for i <- 1..100, do: {:connect, "198.51.100.#{i}", 8443, :public}) == []
    end

    test "many public addresses on one non-web port is a sweep" do
      found = run(for i <- 1..20, do: {:connect, "198.51.100.#{i}", 22, :public})
      assert [%{rule: :scanning, action: :isolate, port: 22, summary: summary}] = found
      assert summary =~ "addresses on port 22"
    end

    test "one host on a non-web port many times isn't a sweep" do
      assert run(for _ <- 1..40, do: {:connect, "198.51.100.9", 22, :public}) == []
    end
  end

  test "mail, IRC and Tor ports isolate; a granted connection is not judged" do
    assert {_, [%{rule: :unusual_port}]} = check({:connect, "198.51.100.7", 25, :public})
    assert {_, [%{rule: :unusual_port}]} = check({:connect, "198.51.100.7", 9050, :public})
    assert {_, []} = check({:connect, "198.51.100.7", 443, :public})
    assert {_, []} = check({:connect, "10.1.2.3", 25, :granted})
  end

  test "DNS around MWT is blocked, not isolated" do
    assert {_, [%{rule: :dns_bypass, action: :block}]} =
             check({:connect, "198.51.100.7", 853, :public})

    assert {_, [%{rule: :dns_bypass, action: :block}]} =
             check({:connect, "198.51.100.7", 53, :public})

    assert {_, [%{rule: :dns_bypass}]} = check({:connect, "1.1.1.1", 443, :public})
    assert {_, [%{rule: :dns_bypass}]} = check({:host, "cloudflare-dns.com", 443})
    assert {_, [%{rule: :dns_bypass}]} = check({:lookup, "dns.google", []})
  end

  describe "commands touching secrets" do
    test "a protected path anywhere in the text, however cased" do
      assert {_, [%{rule: :secret_paths, action: :isolate}]} =
               check({:command, "cat ~/.SSH/id_ed25519 | base64"})

      assert {_, [%{rule: :secret_paths}]} = check({:command, "echo x >> $HOME/.bashrc"})
      assert {_, [%{rule: :secret_paths}]} = check({:command, "ls /home/me/.mwt_client"})
    end

    test "quotes and backslashes slipped between the letters don't hide it" do
      assert {_, [%{rule: :secret_paths}]} = check({:command, ~S(cat ~/.ss""h/id_ed25519)})
      assert {_, [%{rule: :secret_paths}]} = check({:command, ~S(cat ~/.ss\\h/id_ed25519)})
    end

    test "an ordinary command passes" do
      assert {_, []} = check({:command, "kubectl get pods -n web -o json"})
      assert {_, []} = check({:command, "git -C ~/src/app log --oneline -5"})
    end
  end

  describe "asking again after you declined" do
    test "alerts on the second ask after a decline, once" do
      found =
        run([
          {:declined, {:grant, "github"}},
          {:ask, {:grant, "github"}, "GitHub"},
          {:ask, {:grant, "github"}, "GitHub"},
          {:ask, {:grant, "github"}, "GitHub"}
        ])

      assert [%{rule: :asks_after_decline, action: :alert}] = found
    end

    test "asking for what you didn't decline, or long after, is fine" do
      assert run([
               {:declined, {:grant, "github"}},
               {:ask, {:grant, "hex"}, "Hex"},
               {:ask, {:grant, "hex"}, "Hex"}
             ]) == []

      assert run([
               {0, {:declined, {:grant, "github"}}},
               {31 * @minute, {:ask, {:grant, "github"}, "GitHub"}},
               {32 * @minute, {:ask, {:grant, "github"}, "GitHub"}}
             ]) == []
    end
  end

  test "reading many notes alerts" do
    assert [%{rule: :bulk_reads, action: :alert}] = run(for _ <- 1..100, do: :read)
    assert run(for _ <- 1..99, do: :read) == []
  end

  test "a process at a full CPU for 30 minutes alerts; one that rests doesn't" do
    busy = [%{pid: 7, name: "worker", cpu: 99.0}]
    idle = [%{pid: 7, name: "worker", cpu: 3.0}]

    assert [%{rule: :cpu_hog, action: :alert}] =
             run(for at <- 0..30, do: {at * @minute, {:processes, busy}})

    resting =
      for at <- 0..40 do
        {at * @minute, {:processes, if(at == 20, do: idle, else: busy)}}
      end

    assert run(resting) == []
  end

  describe "actions" do
    test "off gives nothing, block and alert as set" do
      {:ok, firewall} = Firewall.set_action(Firewall.new(), :blocked_service, :off)
      assert {_, []} = check({:lookup, "paste.ee", []}, firewall)

      {:ok, firewall} = Firewall.set_action(Firewall.new(), "blocked_service", "block")
      assert {_, [%{action: :block}]} = check({:lookup, "paste.ee", []}, firewall)
    end

    test "an action a rule doesn't take, or an unknown rule, is refused" do
      assert {:error, :bad_action} = Firewall.set_action(Firewall.new(), :cpu_hog, :block)
      assert {:error, :bad_action} = Firewall.set_action(Firewall.new(), :nope, :alert)
    end

    test "an alert is said once per rule and destination in 10 minutes" do
      {:ok, firewall} = Firewall.set_action(Firewall.new(), :blocked_service, :alert)

      found =
        run(
          [
            {0, {:lookup, "paste.ee", []}},
            {@minute, {:lookup, "paste.ee", []}},
            {11 * @minute, {:lookup, "paste.ee", []}}
          ],
          firewall
        )

      assert length(found) == 2
    end

    test "the firewall off sees nothing" do
      firewall = Firewall.set_enabled(Firewall.new(), false)
      assert {_, []} = check({:leak, "GitHub", "evil.example", :request}, firewall)
    end

    test "the worst finding decides" do
      findings = [
        %{rule: :cpu_hog, action: :alert},
        %{rule: :dns_bypass, action: :block},
        %{rule: :credential_leak, action: :isolate}
      ]

      assert Firewall.worst(findings).rule == :credential_leak
      assert Firewall.worst([]) == nil
    end
  end

  describe "lists" do
    test "entries are cleaned, comments skipped, duplicates dropped" do
      {:ok, firewall} =
        Firewall.set_list(
          Firewall.new(),
          :trusted,
          "# mine\nhttps://API.Example.com/v1\n\n*.example.org\napi.example.com\n10.0.0.1\n"
        )

      assert firewall.trusted == ["api.example.com", "*.example.org", "10.0.0.1"]
      assert Firewall.trusted?(firewall, "example.org")
      assert Firewall.trusted?(firewall, "a.b.example.org")
      refute Firewall.trusted?(firewall, "example.com")
    end

    test "a line that is no name says which" do
      assert {:error, message} = Firewall.set_list(Firewall.new(), :blocked, "ok.com\nnot a name")
      assert message =~ "Line 2"
    end
  end

  describe "isolating and releasing" do
    test "forgetting a finding's window starts that count over, and no other" do
      {watch, [finding]} =
        Enum.reduce(
          [
            {:upload, "a.files.example", 443, 3 * @mib, 0},
            {:upload, "b.files.example", 443, 3 * @mib, 0}
          ],
          {Firewall.watch(), []},
          fn observation, {watch, _found} -> check(observation, Firewall.new(), watch, 1) end
        )

      {watch, []} = check({:upload, "other.example", 443, 3 * @mib, 0}, Firewall.new(), watch, 2)
      assert %{rule: :large_upload, key: "files.example"} = finding

      watch = Firewall.forget(watch, finding.rule, finding.key)
      assert {_, []} = check({:upload, "c.files.example", 443, 0, 0}, Firewall.new(), watch, 3)

      # What another destination sent still counts.
      assert {_, [%{rule: :large_upload, host: "other.example"}]} =
               check({:upload, "other.example", 443, 2 * @mib, 0}, Firewall.new(), watch, 3)
    end

    test "each rule's window is forgotten by its finding's key" do
      dns = for i <- 1..41, do: {:lookup, "n#{i}.names.example", []}
      refused = for i <- 1..5, do: {:connect, "10.0.0.#{i}", 5432, :refused}
      ports = for p <- 1..20, do: {:connect, "93.184.216.34", 1000 + p, :public}
      sweep = for a <- 1..20, do: {:connect, "93.184.216.#{a}", 22, :public}

      for observations <- [dns, refused, ports, sweep] do
        {watch, found} =
          Enum.reduce(observations, {Firewall.watch(), []}, fn observation, {watch, found} ->
            {watch, more} = check(observation, Firewall.new(), watch, 1)
            {watch, found ++ more}
          end)

        finding = Enum.find(found, &(&1.action == :isolate))
        watch = Firewall.forget(watch, finding.rule, finding.key)
        {_watch, again} = check(List.last(observations), Firewall.new(), watch, 2)
        assert again == [], "#{finding.rule} under #{inspect(finding.key)}: #{inspect(again)}"
      end
    end

    test "an incident saved before it kept its window forgets the rule's every window" do
      {watch, _} = check({:upload, "a.example", 443, 3 * @mib, 0})
      {watch, _} = check({:upload, "b.example", 443, 3 * @mib, 0}, Firewall.new(), watch)
      assert Firewall.forget(watch, :large_upload, nil).uploads == %{}
      assert Firewall.forget(watch, :credential_leak, "x") == watch
    end

    test "keeps the incident and the events before it; release keeps it listed" do
      finding = %{
        rule: :large_upload,
        action: :isolate,
        summary: "4 MiB",
        host: "files.example",
        port: 443
      }

      now = ~U[2026-11-16 10:00:00Z]
      firewall = Firewall.isolate(Firewall.new(), finding, Enum.to_list(1..50), now, "i1")

      assert Firewall.isolated?(firewall)
      assert firewall.isolated.events == Enum.to_list(1..30)
      assert [%{id: "i1"}] = firewall.incidents

      released = Firewall.release(firewall, now, false)
      refute Firewall.isolated?(released)
      assert [%{released: :release}] = released.incidents
      refute Firewall.trusted?(released, "files.example")

      trusted = Firewall.release(firewall, now, true)
      assert Firewall.trusted?(trusted, "files.example")
      assert [%{released: :trust}] = trusted.incidents
    end

    test "trusting adds the name the finding saw, as an entry of the list" do
      now = ~U[2026-11-16 10:00:00Z]

      for {host, entry} <- [
            {"US-East5-aiplatform.googleapis.com", "us-east5-aiplatform.googleapis.com"},
            {"paste.example.net:80", "paste.example.net"},
            {"93.184.216.34", "93.184.216.34"}
          ] do
        finding = %{rule: :large_upload, action: :isolate, summary: "s", host: host, port: 443}
        firewall = Firewall.isolate(Firewall.new(), finding, [], now, "i1")
        assert entry in Firewall.release(firewall, now, true).trusted
        refute "googleapis.com" in Firewall.release(firewall, now, true).trusted
      end

      # A destination that can't be an entry trusts nothing.
      finding = %{
        rule: :real_value,
        action: :isolate,
        summary: "s",
        host: "not a name",
        port: nil
      }

      firewall = Firewall.isolate(Firewall.new(), finding, [], now, "i1")
      assert Firewall.release(firewall, now, true).trusted == Firewall.new().trusted
    end

    test "isolated by you: no rule, no destination; a release can't trust anything" do
      now = ~U[2026-11-16 10:00:00Z]
      firewall = Firewall.isolate(Firewall.new(), :you, [:before], now, "i1")

      assert %{by: :you, rule: nil, host: nil, events: [:before]} = firewall.isolated
      assert Firewall.isolated_by(firewall.isolated) == "you"

      released = Firewall.release(firewall, now, true)
      refute Firewall.isolated?(released)
      assert released.trusted == Firewall.new().trusted
      assert [%{by: :you, released: :trust}] = released.incidents

      finding = %{rule: :scanning, action: :isolate, summary: "s", host: nil, port: nil}
      by_firewall = Firewall.isolate(Firewall.new(), finding, [], now, "i2")
      assert by_firewall.isolated.by == :firewall
      assert Firewall.isolated_by(by_firewall.isolated) == "the firewall: Scanning"
    end

    test "an incident saved before you could isolate was the firewall's" do
      incident = %{id: "old", rule: :scanning, summary: "s", host: nil, port: nil}
      upgraded = Firewall.upgrade(%{isolated: incident, incidents: [incident]})

      assert upgraded.isolated.by == :firewall
      assert [%{by: :firewall}] = upgraded.incidents
      assert Firewall.upgrade(%{enabled: true}).isolated == nil
    end

    test "every rule is in a group the page shows, with a line to say what it fires on" do
      groups = Keyword.keys(Firewall.groups())

      for rule <- Firewall.rules() do
        assert rule.group in groups, "#{rule.id} has no group the page shows"
        assert is_binary(rule.brief) and rule.brief != ""
      end
    end

    test "a saved firewall from before a field is brought up to date" do
      assert %Firewall{enabled: true, protected: [_ | _]} = Firewall.upgrade(%{enabled: true})
      assert Firewall.upgrade(nil) == Firewall.new()
    end

    test "new default protected paths and credential endpoints reach a saved firewall" do
      a_path = hd(Firewall.default_list(:protected))
      a_mint = hd(Firewall.default_list(:mints))
      saved = %{enabled: true, protected: ["mine/only"], mints: [], blocked: ["kept.example"]}

      upgraded = Firewall.upgrade(saved)
      assert "mine/only" in upgraded.protected
      assert a_path in upgraded.protected
      assert a_mint in upgraded.mints
      # The blocked list is left exactly as saved.
      assert upgraded.blocked == ["kept.example"]
    end
  end

  test "pruning drops what is past every window" do
    {watch, _} = check({:lookup, "a.example.org", []})
    {watch, _} = Firewall.check(Firewall.new(), watch, :read, 0)
    pruned = Firewall.prune(watch, 60 * @minute)
    assert pruned.names == %{}
    assert pruned.reads == []
  end
end
