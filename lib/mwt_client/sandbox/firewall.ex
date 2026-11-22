defmodule MWTClient.Sandbox.Firewall do
  @moduledoc """
  The sandbox's firewall: its rules, the lists you edit, the windows it
  counts in, and the incident that isolates the VM. Pure: what was seen
  (an observation), against what was seen before (the watch), gives
  findings; `MWTClient.Sandbox.Server.Firewall` acts on them.

  The struct is what you set and what happened, saved sealed with the
  rest of the sandbox. The watch (`watch/0`) is the windows: names looked
  up, bytes sent, refused addresses, kept in memory only.

  Rules go by behaviour and by lists, never by attack signatures: bytes
  one way, names shaped to carry data, a placeholder where its grant
  doesn't send it, a path on the protected list in a command the agent
  wrote. Each has an action (`t:action/0`); a finding carries the one
  set for its rule.

  A list entry `example.com` or `*.example.com` covers that name and every
  name under it; an address covers itself.
  """

  @type action :: :isolate | :block | :alert | :off

  @type rule ::
          :credential_leak
          | :real_value
          | :blocked_service
          | :dns_tunnel
          | :large_upload
          | :scanning
          | :unusual_port
          | :secret_paths
          | :dns_bypass
          | :cpu_hog
          | :asks_after_decline
          | :bulk_reads
          | :credential_inbound
          | :credential_mint

  @typedoc "What a sensor saw."
  @type observation ::
          {:lookup, String.t(), [{String.t(), String.t()}]}
          | {:connect, String.t(), :inet.port_number(), :public | :refused | :granted}
          | {:host, String.t(), :inet.port_number()}
          | {:upload, String.t(), :inet.port_number(), non_neg_integer(), non_neg_integer()}
          | {:leak, String.t(), String.t(), :request | :plaintext}
          | {:value, String.t(), String.t() | nil,
             :request | :plaintext | :echo | :lookup | :ask | :tool | :handoff | :workspace}
          | {:command, String.t()}
          | {:declined, term()}
          | {:ask, term(), String.t()}
          | :read
          | {:processes, [%{pid: integer(), name: String.t(), cpu: number() | nil}]}
          | {:inbound, String.t(), String.t(), :command | :call | :workspace}
          | {:mint, String.t(), String.t(), String.t()}

  @type finding :: %{
          rule: rule(),
          action: action(),
          summary: String.t(),
          host: String.t() | nil,
          port: :inet.port_number() | nil
        }

  @typedoc """
  An isolation: by the firewall, on a finding (its rule, what it saw and
  where), or by you, with the switch (no rule, no destination).
  """
  @type incident :: %{
          id: String.t(),
          at: DateTime.t(),
          by: :firewall | :you,
          rule: rule() | nil,
          summary: String.t(),
          host: String.t() | nil,
          port: :inet.port_number() | nil,
          events: list(),
          grants_on: [grant_on()],
          released_at: DateTime.t() | nil,
          released: nil | :release | :trust
        }

  @typedoc """
  A grant that was on when the VM was isolated, as it was: until when, for
  how long it was turned on, and its allowances. Releasing turns it back
  on so, for the time it has left.
  """
  @type grant_on :: %{
          id: String.t(),
          expires_at: DateTime.t() | nil,
          minutes: pos_integer() | :until_off | nil,
          allowances: list()
        }

  @kib 1024
  @mib 1024 * 1024
  @minute 60_000

  @upload_bytes 4 * @mib
  @upload_window 10 * @minute
  @names_per_domain 40
  @names_bytes 1536
  @names_window 10 * @minute
  @long_label 50
  @long_name 100
  @long_names 3
  @refused_addresses 5
  @ports_per_address 20
  @sweep_addresses 20
  @scan_window @minute
  # Web and API ports: many addresses on one of these in a minute is
  # ordinary browsing, not a sweep.
  @web_ports [80, 443, 8080, 8443, 8000, 8888]
  @cpu_share 90
  @cpu_for 30 * @minute
  @declined_for 30 * @minute
  @asks_again 2
  @reads 100
  @reads_window 10 * @minute
  @said_for 10 * @minute
  @watched 10_000

  @unusual_ports [25, 465, 587, 2525, 6667, 6697, 9001, 9030, 9050, 9150]

  # Public resolvers that answer DNS over HTTPS or TLS, by name and address:
  # a lookup through one never reaches MWT.
  @resolver_names ~w(
    dns.google dns.google.com cloudflare-dns.com one.one.one.one quad9.net
    doh.opendns.com nextdns.io cleanbrowsing.org adguard-dns.com
    dns.adguard.com mullvad.net dns.sb doh.libredns.gr dns.controld.com
    freedns.controld.com dns.rubyfish.cn doh.familyshield.opendns.com
  )
  @resolver_addresses ~w(
    1.1.1.1 1.0.0.1 1.1.1.2 1.0.0.2 1.1.1.3 1.0.0.3
    8.8.8.8 8.8.4.4 9.9.9.9 9.9.9.11 149.112.112.112 149.112.112.11
    208.67.222.222 208.67.220.220 94.140.14.14 94.140.15.15 94.140.14.15
    76.76.2.0 76.76.10.0 185.228.168.9 185.228.169.9
    2606:4700:4700::1111 2606:4700:4700::1001 2606:4700:4700::1112
    2001:4860:4860::8888 2001:4860:4860::8844
    2620:fe::fe 2620:fe::9 2620:119:35::35 2620:119:53::53
  )

  # A country's second level, under which names are given out as under a
  # top-level domain (`example.co.uk`, `example.com.br`).
  @second_levels ~w(co com net org gov edu ac or ne gob gouv go mil ltd plc nic)

  # Providers whose DNS answers every name under them: names there are a
  # customer's to choose, the questions asked never theirs to read. The
  # rule on DNS names doesn't judge them.
  @providers ~w(
    amazonaws.com cloudfront.net awsglobalaccelerator.com
    azure.com azurewebsites.net windows.net azureedge.net azurefd.net
    trafficmanager.net cloudapp.net azurecr.io
    googleapis.com googleusercontent.com gvt1.com appspot.com run.app
    cloudfunctions.net web.app firebaseapp.com pkg.dev
    github.io githubusercontent.com
    vercel.app netlify.app herokuapp.com pages.dev workers.dev fly.dev onrender.com
    akamaiedge.net akamaized.net edgekey.net edgesuite.net fastly.net fastlylb.net
    cloudflare.net
  )

  @trusted ~w(*.anthropic.com *.claude.ai *.claude.com *.openai.com *.chatgpt.com)

  # Where data goes to be picked up by someone else (paste sites, file drops,
  # request catchers), tunnels that open the VM to the internet, and mining
  # pools.
  @blocked ~w(
    pastebin.com paste.ee hastebin.com dpaste.com dpaste.org rentry.co
    privatebin.net 0x0.st termbin.com sprunge.us ix.io
    transfer.sh file.io bashupload.com temp.sh tmpfiles.org gofile.io
    catbox.moe filebin.net uguu.se pixeldrain.com oshi.at keep.sh
    webhook.site requestbin.com pipedream.net requestcatcher.com beeceptor.com
    hookbin.com requestrepo.com interact.sh oast.fun oast.pro oast.live
    oast.site oast.online oast.me burpcollaborator.net dnslog.cn ceye.io
    ngrok.io ngrok.app ngrok-free.app trycloudflare.com argotunnel.com
    loca.lt serveo.net localhost.run bore.pub tunnelmole.com
    tmate.io sshx.io devtunnels.ms pinggy.io packetriot.net expose.sh
    smee.io ntfy.sh dpaste.com envs.sh paste.c-net.org paste.rs
    nanopool.org supportxmr.com minexmr.com 2miners.com f2pool.com
    moneroocean.stream hashvault.pro c3pool.com herominers.com unmineable.com
    xmrpool.eu pool.hashvault.pro gulf.moneroocean.stream zephyr.herominers.com
    ethermine.org poolin.com antpool.com viabtc.com prohashing.com
  )

  # Hosts and paths whose answers are credentials: token exchanges, key
  # creation, a registry's token. A grant's value sent to one would mint a
  # credential the VM then holds.
  @mints ~w(
    sts.amazonaws.com
    sts.googleapis.com
    oauth2.googleapis.com/token
    iamcredentials.googleapis.com
    iam.googleapis.com/v1/projects/*/serviceAccounts/*/keys
    login.microsoftonline.com
    api.github.com/user/keys
    api.github.com/repos/*/*/keys
    api.github.com/app/installations/*/access_tokens
    github.com/login/oauth/access_token
    ghcr.io/token
    auth.docker.io/token
    *.pkg.dev/v2/token
    gitlab.com/oauth/token
    gitlab.com/api/v4/personal_access_tokens
    gitlab.com/api/v4/projects/*/access_tokens
    gitlab.com/api/v4/groups/*/access_tokens
    api.github.com/repos/*/*/actions/runners/registration-token
    api.github.com/orgs/*/actions/runners/registration-token
    www.googleapis.com/oauth2/*/token
    hex.pm/api/keys
    api.openai.com/v1/realtime/client_secrets
    api.openai.com/v1/organization/admin_api_keys
    registry.npmjs.org/-/npm/v1/tokens
  )

  # Your keys and credential stores, MWT's own data, and where things start
  # from again.
  @protected [
    ".ssh/id_",
    ".ssh/authorized_keys",
    ".aws/credentials",
    ".config/gcloud",
    ".azure/",
    ".docker/config.json",
    ".git-credentials",
    ".netrc",
    ".gnupg",
    ".password-store",
    ".config/gh/hosts.yml",
    ".kube/config",
    ".npmrc",
    ".pypirc",
    ".cargo/credentials",
    ".pgpass",
    ".vault-token",
    ".config/op",
    ".config/git/credentials",
    ".ssh/config",
    ".optmem",
    ".mwt_client",
    ".local/share/keyrings",
    "Library/Keychains",
    ".mozilla/firefox",
    ".config/google-chrome",
    ".config/chromium",
    "Library/Application Support/Google/Chrome",
    "crontab",
    ".bashrc",
    ".bash_profile",
    ".zshrc",
    ".zprofile",
    ".profile",
    ".config/autostart",
    ".config/systemd/user",
    "Library/LaunchAgents"
  ]

  @groups [
    credentials: "Credentials",
    network: "Network",
    agent: "Agent and VM"
  ]

  @rules [
    %{
      id: :credential_leak,
      group: :credentials,
      brief: "A placeholder sent where its grant doesn't go.",
      name: "Credential sent elsewhere",
      text:
        "A placeholder going to a host its grant doesn't list (in a header, the target or the body), in a tunnel, or inside a DNS name. Trusted destinations aren't spared.",
      default: :isolate,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :real_value,
      group: :credentials,
      brief: "A grant's real value going out, or coming in.",
      name: "Real credential in traffic",
      text:
        "A token grant's real value in what the VM sends that MWT reads (a request, a plaintext tunnel, a lookup, an ask, a write through MWT's tools, a handoff, a file of the workspace's from-vm), or coming back to it in an answer. It never goes; out, the VM holds it: replace that credential.",
      default: :isolate,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :blocked_service,
      group: :network,
      brief: "A blocked name, looked up or connected to.",
      name: "Blocked services",
      text: "A name on the blocked list, looked up or connected to.",
      default: :isolate,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :dns_tunnel,
      group: :network,
      brief: "DNS names shaped to carry data out.",
      name: "Data in DNS names",
      text:
        "A label of 50 characters or more, or 100 or more before the domain: one is refused, three under one domain in 10 minutes set off the rule. Over 40 names, or 1.5 KiB of names, under one domain in 10 minutes. Names under a cloud provider's own domains (amazonaws.com, github.io, vercel.app, …) aren't judged: no customer reads their DNS.",
      default: :isolate,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :large_upload,
      group: :network,
      brief: "4 MiB out to one place, little coming back.",
      name: "Large upload",
      text:
        "4 MiB or more sent through tunnels to one public destination in 10 minutes, with less than a quarter of it coming back.",
      default: :isolate,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :scanning,
      group: :network,
      brief: "Many addresses or ports tried in a minute.",
      name: "Scanning",
      text:
        "5 private or reserved address:ports refused in a minute, 20 ports of one public address in a minute, or 20 public addresses on one non-web port (SSH, databases, RDP) in a minute.",
      default: :isolate,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :unusual_port,
      group: :network,
      brief: "A public address on a mail, IRC or Tor port.",
      name: "Mail, IRC and Tor ports",
      text:
        "A public address on a mail, IRC or Tor port: 25, 465, 587, 2525, 6667, 6697, 9001, 9030, 9050, 9150.",
      default: :isolate,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :secret_paths,
      group: :agent,
      brief: "A host command naming a protected path.",
      name: "Command touching secrets",
      text:
        "A command the agent wrote, to run on your machine, that names a path on the protected list. The card is refused.",
      default: :isolate,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :dns_bypass,
      group: :network,
      brief: "DNS straight to a public resolver.",
      name: "DNS around MWT",
      text:
        "DNS straight to a public address (port 53 or 853), or a public DNS-over-HTTPS resolver, by name or address.",
      default: :block,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :cpu_hog,
      group: :agent,
      brief: "One process at 90% of a CPU for 30 minutes.",
      name: "A process pegging a CPU",
      text: "One process in the VM at 90% of a CPU or more for 30 minutes.",
      default: :alert,
      actions: [:isolate, :alert, :off]
    },
    %{
      id: :asks_after_decline,
      group: :agent,
      brief: "Twice more in 30 minutes, after you said no.",
      name: "Asking again after you declined",
      text: "Asking twice more, within 30 minutes, for a grant or a command you declined.",
      default: :alert,
      actions: [:isolate, :alert, :off]
    },
    %{
      id: :bulk_reads,
      group: :agent,
      brief: "100 reads of your notes in 10 minutes.",
      name: "Reading many notes",
      text: "100 reads of your notes, diagrams or flash cards in 10 minutes, over MWT's tools.",
      default: :alert,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :credential_mint,
      group: :credentials,
      brief: "A grant's value sent to mint a new credential.",
      name: "Minting a credential",
      text:
        "A request that would carry a grant's real value to a credential endpoint on the list: a token exchange, key creation, a registry's token. Its answer would be a credential the VM holds. Blocked, it is refused and never sent.",
      default: :block,
      actions: [:isolate, :block, :alert, :off]
    },
    %{
      id: :credential_inbound,
      group: :credentials,
      brief: "A key or token in what comes back to the VM.",
      name: "Credential entering the VM",
      text:
        "A command's output or a request subgrant's answer, on its way to the VM, holding something shaped like a credential (a private key, a JWT, a known token prefix). Blocked, it waits for you, whatever its approval mode. A token grant's real value in a command's output always waits; in an answer, it is written out as the grant's name. The VM did nothing wrong, so this never isolates it.",
      default: :block,
      actions: [:block, :alert, :off]
    }
  ]

  @rule_ids Enum.map(@rules, & &1.id)
  @lists [:trusted, :blocked, :protected, :mints]
  @list_limit 500
  @incident_limit 20
  @incident_events 30

  defstruct enabled: true,
            actions: %{},
            trusted: @trusted,
            blocked: @blocked,
            protected: @protected,
            mints: @mints,
            isolated: nil,
            incidents: []

  @type t :: %__MODULE__{
          enabled: boolean(),
          actions: %{rule() => action()},
          trusted: [String.t()],
          blocked: [String.t()],
          protected: [String.t()],
          mints: [String.t()],
          isolated: incident() | nil,
          incidents: [incident()]
        }

  @doc "The firewall as it starts: on, every rule at its default, the lists as MWT fills them."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  A saved firewall brought up to date with this code; nil (none saved yet)
  is a new one. New default protected paths and credential endpoints are
  merged in, so a saved firewall gains them: both only ever refuse a use,
  so a re-added entry breaks nothing. The blocked and trusted lists are
  left as you saved them (a re-added blocked entry could isolate the VM on
  a service you cleared); the \"reset to MWT's\" button brings their
  latest. An incident saved before you could isolate the VM yourself was
  the firewall's.
  """
  @spec upgrade(t() | map() | nil) :: t()
  def upgrade(nil), do: new()

  def upgrade(%{} = saved) do
    firewall = struct(__MODULE__, Map.delete(saved, :__struct__))

    %{
      firewall
      | protected: merge_defaults(firewall.protected, @protected),
        mints: merge_defaults(firewall.mints, @mints),
        isolated: firewall.isolated && by_firewall(firewall.isolated),
        incidents: Enum.map(firewall.incidents || [], &by_firewall/1)
    }
  end

  defp by_firewall(incident), do: Map.put_new(incident, :by, :firewall)

  # The saved entries, then every current default it doesn't already hold.
  defp merge_defaults(saved, default) when is_list(saved),
    do: Enum.uniq(saved ++ Enum.reject(default, &(&1 in saved)))

  defp merge_defaults(_not_a_list, default), do: default

  @doc """
  Every rule: its id, group, name, what it fires on in a line (`brief`) and
  in full (`text`), its default and the actions it takes.
  """
  def rules, do: @rules

  @doc "The groups the rules fall into, in the order the page shows them: `{id, name}`."
  def groups, do: @groups

  @doc "The lists you edit."
  def lists, do: @lists

  @doc "Each list as MWT fills it."
  def default_list(:trusted), do: @trusted
  def default_list(:blocked), do: @blocked
  def default_list(:protected), do: @protected
  def default_list(:mints), do: @mints

  @doc "The action set for `rule`, or its default."
  @spec action(t(), rule()) :: action()
  def action(%__MODULE__{actions: actions}, rule) do
    Map.get(actions, rule) || Enum.find(@rules, &(&1.id == rule)).default
  end

  @doc "The rule's name, as the pages say it."
  def rule_name(rule) do
    case Enum.find(@rules, &(&1.id == rule)) do
      nil -> to_string(rule)
      found -> found.name
    end
  end

  @doc "Whether the VM is isolated."
  @spec isolated?(t()) :: boolean()
  def isolated?(%__MODULE__{isolated: isolated}), do: not is_nil(isolated)

  ## Settings

  @doc "Turns the firewall on or off."
  def set_enabled(%__MODULE__{} = firewall, enabled?) when is_boolean(enabled?),
    do: %{firewall | enabled: enabled?}

  @doc "Sets the action of one rule; one it doesn't take is refused."
  @spec set_action(t(), rule() | String.t(), action() | String.t()) ::
          {:ok, t()} | {:error, :bad_action}
  def set_action(%__MODULE__{} = firewall, rule, action) do
    with %{} = found <- Enum.find(@rules, &(to_string(&1.id) == to_string(rule))),
         action when not is_nil(action) <-
           Enum.find(found.actions, &(to_string(&1) == to_string(action))) do
      actions =
        if action == found.default,
          do: Map.delete(firewall.actions, found.id),
          else: Map.put(firewall.actions, found.id, action)

      {:ok, %{firewall | actions: actions}}
    else
      _unknown -> {:error, :bad_action}
    end
  end

  @doc """
  Sets a list from text, one entry a line; blank lines and lines starting
  with `#` are skipped. Names are lowercased, a URL's scheme and path
  dropped. Refused with the line that can't be an entry.
  """
  @spec set_list(t(), :trusted | :blocked | :protected | :mints, String.t()) ::
          {:ok, t()} | {:error, String.t()}
  def set_list(%__MODULE__{} = firewall, list, text) when list in @lists and is_binary(text) do
    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} -> {String.trim(line), number} end)
      |> Enum.reject(fn {line, _} -> line == "" or String.starts_with?(line, "#") end)

    entries =
      Enum.reduce_while(lines, {:ok, []}, fn {line, number}, {:ok, acc} ->
        case entry(list, line) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          :error -> {:halt, {:error, "Line #{number} isn't a #{noun(list)}: #{line}"}}
        end
      end)

    case entries do
      {:ok, entries} when length(entries) > @list_limit ->
        {:error, "A list holds #{@list_limit} entries at most."}

      {:ok, entries} ->
        {:ok, Map.put(firewall, list, entries |> Enum.reverse() |> Enum.uniq())}

      error ->
        error
    end
  end

  defp noun(:protected), do: "path"
  defp noun(:mints), do: "host, or host/path"
  defp noun(_destinations), do: "name or address"

  defp entry(:protected, line) do
    if String.length(line) <= 200 and String.printable?(line), do: {:ok, line}, else: :error
  end

  # A host, or a host and a path: `*.` before a host covers the names
  # under it; `*` alone is any one segment of the path.
  defp entry(:mints, line) do
    line = String.replace(line, ~r{\A[a-zA-Z][a-zA-Z0-9+.-]*://}, "")
    [host | path] = String.split(line, "/", parts: 2)

    with {:ok, host} <- entry(:trusted, host),
         false <- address?(host),
         path = path |> List.first("") |> String.split(["?", "#"], parts: 2) |> hd(),
         true <- String.length(path) <= 200 and path =~ ~r{\A[A-Za-z0-9._~*@:%+=,;!$'()/-]*\z} do
      case String.trim(path, "/") do
        "" -> {:ok, host}
        path -> {:ok, host <> "/" <> path}
      end
    else
      _ -> :error
    end
  end

  defp entry(_destinations, line) do
    host =
      line
      |> String.downcase()
      |> String.replace(~r{\A[a-z][a-z0-9+.-]*://}, "")
      |> String.split(["/", "?", "#"], parts: 2)
      |> hd()
      |> String.trim_trailing(".")

    cond do
      address?(host) ->
        {:ok, host}

      host =~ ~r/\A(\*\.)?[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*\z/ and
          byte_size(host) <= 253 ->
        {:ok, host}

      true ->
        :error
    end
  end

  defp address?(text), do: match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(text)))

  @doc "Whether `host`, a name or an address, is on `entries`."
  @spec listed?(String.t() | nil, [String.t()]) :: boolean()
  def listed?(nil, _entries), do: false

  def listed?(host, entries) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    Enum.any?(entries, fn entry ->
      name = String.trim_leading(entry, "*.")
      host == name or String.ends_with?(host, "." <> name)
    end)
  end

  @doc "Whether the rules on destinations spare `host`."
  def trusted?(%__MODULE__{trusted: trusted}, host), do: listed?(host, trusted)

  @doc """
  The entry of `mints`, the credential endpoints, that a request to `host`
  and `path` meets, or nil. The host goes as on the other lists; an
  entry's path covers the request's when each of its segments is the
  request's (`*` any one) and the request's may go on after them. The
  query is not read.

      iex> alias MWTClient.Sandbox.Firewall
      iex> Firewall.mint(["api.example.com/user/keys"], "API.example.com", "/user/keys/7?x=1")
      "api.example.com/user/keys"
      iex> Firewall.mint(["*.registry.example/v2/token"], "eu.registry.example", "/v2/token")
      "*.registry.example/v2/token"
      iex> Firewall.mint(["iam.example.com/v1/*/keys"], "iam.example.com", "/v1/p/sa/keys")
      nil
      iex> Firewall.mint(["sts.example.com"], "sts.example.com", "/")
      "sts.example.com"

      iex> Firewall.mint(["api.example.com/user/keys"], "api.example.com", "/user/%6beys")
      "api.example.com/user/keys"

      iex> Firewall.mint(["api.example.com/user/keys"], "api.example.com", "/x/../user/./keys")
      "api.example.com/user/keys"
  """
  @spec mint([String.t()], String.t() | nil, String.t() | nil) :: String.t() | nil
  def mint(_entries, nil, _path), do: nil

  def mint(entries, host, path) do
    segments = segments(path || "/")

    Enum.find(entries, fn entry ->
      [entry_host | entry_path] = String.split(entry, "/", parts: 2)

      listed?(host, [entry_host]) and
        covers?(segments(List.first(entry_path, "")), segments)
    end)
  end

  # A path as the host sees it, so an obfuscated one still meets its entry:
  # the query dropped, percent-encoding decoded, and `.`/`..` resolved.
  defp segments(path) do
    path
    |> String.split(["?", "#"], parts: 2)
    |> hd()
    |> decode_percent()
    |> String.split("/", trim: true)
    |> resolve_dots([])
  end

  defp decode_percent(path) do
    URI.decode(path)
  rescue
    _malformed -> path
  end

  defp resolve_dots([], acc), do: Enum.reverse(acc)
  defp resolve_dots(["." | rest], acc), do: resolve_dots(rest, acc)
  defp resolve_dots([".." | rest], [_popped | acc]), do: resolve_dots(rest, acc)
  defp resolve_dots([".." | rest], []), do: resolve_dots(rest, [])
  defp resolve_dots([segment | rest], acc), do: resolve_dots(rest, [segment | acc])

  defp covers?([], _path), do: true
  defp covers?(["*" | entry], [_any | path]), do: covers?(entry, path)
  defp covers?([same | entry], [same | path]), do: covers?(entry, path)
  defp covers?(_entry, _path), do: false

  @doc """
  The entries of `mints` on hosts a token grant listing `hosts` would
  send its value to: where the grant's value would be refused.

      iex> MWTClient.Sandbox.Firewall.mints_under(["sts.example.com", "api.other.test/keys"], ["*.example.com"])
      ["sts.example.com"]
  """
  @spec mints_under([String.t()], [String.t()]) :: [String.t()]
  def mints_under(entries, hosts) do
    Enum.filter(entries, fn entry ->
      [entry_host | _path] = String.split(entry, "/", parts: 2)
      bare = String.trim_leading(entry_host, "*.")

      Enum.any?(hosts, fn host ->
        host = host |> String.trim() |> String.downcase()

        MWTClient.Sandbox.Policy.host_listed?(bare, [host]) or
          listed?(String.trim_leading(host, "*."), [entry_host])
      end)
    end)
  end

  @doc """
  The credential endpoint a request to `host` and `path` meets while the
  firewall watches, or nil: off, or with the rule off, none.
  """
  @spec minting(t(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def minting(%__MODULE__{enabled: false}, _host, _path), do: nil

  def minting(%__MODULE__{} = firewall, host, path) do
    if action(firewall, :credential_mint) == :off,
      do: nil,
      else: mint(firewall.mints, host, path)
  end

  ## Isolating

  @doc """
  Isolates the VM on `finding`, or because you did (`:you`), keeping the
  events before it (newest first; the last #{@incident_events}) and the
  grants that were on (`grants_on`), for releasing to turn back on.
  """
  @spec isolate(t(), finding() | :you, list(), DateTime.t(), String.t(), [grant_on()]) :: t()
  def isolate(%__MODULE__{} = firewall, cause, events, now, id, grants_on \\ []) do
    incident =
      Map.merge(cause(cause), %{
        id: id,
        at: now,
        events: Enum.take(events, @incident_events),
        grants_on: grants_on,
        released_at: nil,
        released: nil
      })

    %{
      firewall
      | isolated: incident,
        incidents: Enum.take([incident | firewall.incidents], @incident_limit)
    }
  end

  defp cause(:you),
    do: %{by: :you, rule: nil, summary: "You isolated the VM", host: nil, port: nil}

  defp cause(%{rule: rule} = finding),
    do: %{
      by: :firewall,
      rule: rule,
      summary: finding.summary,
      host: finding.host,
      port: finding.port
    }

  @doc """
  Who isolated the VM, as the pages say it: `"you"`, or `"the firewall:
  RULE"`.
  """
  @spec isolated_by(incident()) :: String.t()
  def isolated_by(%{by: :you}), do: "you"
  def isolated_by(%{rule: rule}), do: "the firewall: " <> rule_name(rule)

  @doc """
  Ends the isolation. With `trust: true`, the incident's destination joins
  the trusted list.
  """
  @spec release(t(), DateTime.t(), boolean()) :: t()
  def release(%__MODULE__{isolated: nil} = firewall, _now, _trust?), do: firewall

  def release(%__MODULE__{isolated: incident} = firewall, now, trust?) do
    released = %{incident | released_at: now, released: if(trust?, do: :trust, else: :release)}

    trusted =
      if (trust? and incident.host) && not trusted?(firewall, incident.host),
        do: firewall.trusted ++ [String.downcase(incident.host)],
        else: firewall.trusted

    %{
      firewall
      | isolated: nil,
        trusted: trusted,
        incidents: Enum.map(firewall.incidents, &if(&1.id == incident.id, do: released, else: &1))
    }
  end

  ## Watching

  @doc "The windows, empty: in memory only."
  def watch do
    %{
      names: %{},
      long: %{},
      uploads: %{},
      refused: [],
      ports: %{},
      sweep: %{},
      cpu: %{},
      declined: %{},
      reads: [],
      said: %{}
    }
  end

  @doc """
  Checks one observation at `now` (monotonic milliseconds): the watch with
  it counted, and what it gives, each finding with its rule's action. A
  rule that is off gives nothing, and an alert is given once per rule and
  destination in 10 minutes. The firewall off watches nothing.
  """
  @spec check(t(), map(), observation(), integer()) :: {map(), [finding()]}
  def check(%__MODULE__{enabled: false}, watch, _observation, _now), do: {watch, []}

  def check(%__MODULE__{} = firewall, watch, observation, now) do
    {watch, seen} = sense(firewall, watch, observation, now)

    Enum.reduce(seen, {watch, []}, fn seen_one, {watch, found} ->
      {rule, key, summary, host, port, cap} = with_cap(seen_one)

      case capped(action(firewall, rule), cap) do
        :off ->
          {watch, found}

        :alert ->
          case watch.said do
            %{{^rule, ^key} => at} when now - at < @said_for ->
              {watch, found}

            _not_said ->
              {put_in(watch.said[{rule, key}], now),
               found ++ [finding(rule, :alert, summary, host, port)]}
          end

        action ->
          {watch, found ++ [finding(rule, action, summary, host, port)]}
      end
    end)
  end

  defp finding(rule, action, summary, host, port),
    do: %{rule: rule, action: action, summary: summary, host: host, port: port}

  defp with_cap({rule, key, summary, host, port}), do: {rule, key, summary, host, port, nil}
  defp with_cap({_rule, _key, _summary, _host, _port, _cap} = seen), do: seen

  # What one sighting can't say on its own goes no further than `cap`: it
  # is refused, and isolates only once it comes again.
  defp capped(:isolate, :block), do: :block
  defp capped(action, _cap), do: action

  @doc "The finding that decides: isolate over block over alert; nil when there is none."
  @spec worst([finding()]) :: finding() | nil
  def worst(findings) do
    Enum.min_by(
      findings,
      &Enum.find_index([:isolate, :block, :alert], fn a -> a == &1.action end),
      fn ->
        nil
      end
    )
  end

  @doc "The watch with what is past every window dropped, so it can't grow without end."
  def prune(watch, now) do
    %{
      watch
      | names: prune_map(watch.names, fn {at, _name} -> now - at < @names_window end),
        long:
          prune_map(Map.get(watch, :long, %{}), fn {at, _name} -> now - at < @names_window end),
        uploads: prune_map(watch.uploads, fn {at, _up, _down} -> now - at < @upload_window end),
        refused: Enum.filter(watch.refused, fn {at, _} -> now - at < @scan_window end),
        ports: prune_map(watch.ports, fn {at, _port} -> now - at < @scan_window end),
        sweep:
          prune_map(Map.get(watch, :sweep, %{}), fn {at, _addr} -> now - at < @scan_window end),
        declined: Map.filter(watch.declined, fn {_key, {at, _}} -> now - at < @declined_for end),
        reads: Enum.filter(watch.reads, &(now - &1 < @reads_window)),
        said: Map.filter(watch.said, fn {_key, at} -> now - at < @said_for end)
    }
  end

  defp prune_map(map, keep?) do
    map
    |> Enum.map(fn {key, entries} -> {key, Enum.filter(entries, keep?)} end)
    |> Enum.reject(fn {_key, entries} -> entries == [] end)
    |> Map.new()
  end

  ## The rules

  # Each clause gives the watch and what it saw, as {rule, key, summary,
  # host, port}, or with a cap after them (`capped/2`): the key says what
  # an alert is said once for.

  defp sense(firewall, watch, {:lookup, name, placeholders}, now) do
    name = name |> String.downcase() |> String.trim_trailing(".")

    leaks =
      for {grant, placeholder} <- placeholders,
          is_binary(placeholder) and byte_size(placeholder) >= 40,
          String.contains?(name, placeholder |> String.slice(-40, 40) |> String.downcase()),
          do: {:credential_leak, name, "#{grant}'s placeholder inside a lookup", name, nil}

    if trusted?(firewall, name) do
      {watch, leaks}
    else
      domain = domain(name)

      listed =
        cond do
          listed?(name, firewall.blocked) ->
            [{:blocked_service, domain, "Looked up #{name}, on the blocked list", name, nil}]

          listed?(name, @resolver_names) ->
            [{:dns_bypass, name, "Looked up #{name}, a DNS-over-HTTPS resolver", name, nil}]

          true ->
            []
        end

      {watch, shaped} = names(watch, name, domain, now)
      {watch, leaks ++ listed ++ shaped}
    end
  end

  defp sense(firewall, watch, {:connect, address, port, :public}, now) do
    if trusted?(firewall, address) do
      {watch, []}
    else
      at = "#{address}:#{port}"

      listed =
        cond do
          listed?(address, firewall.blocked) ->
            [
              {:blocked_service, address, "Connected to #{at}, on the blocked list", address,
               port}
            ]

          port == 853 ->
            [{:dns_bypass, address, "DNS over TLS to #{at}", address, port}]

          port == 53 ->
            [{:dns_bypass, address, "DNS straight to #{at}, around MWT", address, port}]

          address in @resolver_addresses and port == 443 ->
            [{:dns_bypass, address, "DNS over HTTPS to #{at}", address, port}]

          port in @unusual_ports ->
            [{:unusual_port, at, "Connected to #{at}: #{port_words(port)}", address, port}]

          true ->
            []
        end

      ports =
        watch.ports
        |> Map.get(address, [])
        |> Enum.filter(fn {seen, _} -> now - seen < @scan_window end)
        |> then(&[{now, port} | Enum.reject(&1, fn {_, seen} -> seen == port end)])
        |> Enum.take(@ports_per_address * 2)

      watch = put_in(capped_window(watch, :ports).ports[address], ports)

      scanned =
        if length(ports) >= @ports_per_address,
          do: [
            {:scanning, address, "#{length(ports)} ports of #{address} in a minute", address,
             port}
          ],
          else: []

      {watch, swept} = sweep(watch, address, port, now)

      {watch, listed ++ scanned ++ swept}
    end
  end

  defp sense(_firewall, watch, {:connect, address, port, :refused}, now) do
    at = "#{address}:#{port}"

    refused =
      watch.refused
      |> Enum.filter(fn {seen, _} -> now - seen < @scan_window end)
      |> then(&[{now, at} | Enum.reject(&1, fn {_, seen} -> seen == at end)])
      |> Enum.take(@refused_addresses * 4)

    watch = %{watch | refused: refused}

    if length(refused) >= @refused_addresses,
      do:
        {watch,
         [
           {:scanning, :private,
            "#{length(refused)} private or reserved addresses refused in a minute, the last #{at}",
            address, port}
         ]},
      else: {watch, []}
  end

  defp sense(_firewall, watch, {:connect, _address, _port, :granted}, _now), do: {watch, []}

  defp sense(firewall, watch, {:host, name, port}, _now) do
    name = String.downcase(name)

    cond do
      trusted?(firewall, name) ->
        {watch, []}

      listed?(name, firewall.blocked) ->
        {watch,
         [
           {:blocked_service, domain(name), "Connected to #{name}, on the blocked list", name,
            port}
         ]}

      listed?(name, @resolver_names) ->
        {watch, [{:dns_bypass, name, "DNS over HTTPS to #{name}", name, port}]}

      true ->
        {watch, []}
    end
  end

  # Counted by domain for a name (so many subdomains of one domain fold
  # together), by address otherwise.
  defp sense(firewall, watch, {:upload, destination, port, up, down}, now) do
    if trusted?(firewall, destination) do
      {watch, []}
    else
      key = upload_key(destination)

      flows =
        watch.uploads
        |> Map.get(key, [])
        |> Enum.filter(fn {at, _, _} -> now - at < @upload_window end)
        |> then(&if(up + down > 0, do: [{now, up, down} | &1], else: &1))
        |> Enum.take(1_000)

      watch = put_in(capped_window(watch, :uploads).uploads[key], flows)
      sent = flows |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      back = flows |> Enum.map(&elem(&1, 2)) |> Enum.sum()

      where = if key == destination, do: key, else: "#{destination} (#{key})"

      if sent >= @upload_bytes and back * 4 < sent,
        do:
          {watch,
           [
             {:large_upload, key,
              "#{size(sent)} sent to #{where} in 10 minutes, #{size(back)} back", key, port}
           ]},
        else: {watch, []}
    end
  end

  defp sense(_firewall, watch, {:leak, grant, host, how}, _now) do
    summary =
      case how do
        :request -> "#{grant}'s placeholder sent to #{host}, which the grant doesn't list"
        :plaintext -> "#{grant}'s placeholder in a tunnel to #{host}"
      end

    {watch, [{:credential_leak, host, summary, host, nil}]}
  end

  defp sense(_firewall, watch, {:mint, grant, host, entry}, _now) do
    summary = "#{grant}'s value on its way to #{host}, a credential endpoint (#{entry})"
    {watch, [{:credential_mint, {grant, entry}, summary, host, 443}]}
  end

  # Never the text it was found in: that holds the credential.
  defp sense(_firewall, watch, {:inbound, title, words, how}, _now) do
    what =
      case how do
        :call -> "The answer to #{title}"
        :workspace -> "The workspace's #{title}"
        :command -> "The output of #{title}"
      end

    {watch, [{:credential_inbound, {title, words}, "#{what} holds #{words}", nil, nil}]}
  end

  # Never the text it was found in: that holds the value.
  defp sense(_firewall, watch, {:value, grant, destination, how}, _now) do
    summary =
      case how do
        :echo ->
          "#{grant}'s real value came back from #{destination} in an answer, cut before the VM got it"

        :lookup ->
          "#{grant}'s real value inside a DNS lookup: the VM holds it. Replace it at its service"

        :ask ->
          "#{grant}'s real value in an ask on the agent channel: the VM holds it. Replace it at its service"

        :tool ->
          "#{grant}'s real value in a write through MWT's tools: the VM holds it. Replace it at its service"

        how when how in [:handoff, :workspace] ->
          "#{grant}'s real value in #{destination}: the VM holds it. Replace it at its service"

        out when out in [:request, :plaintext] ->
          "#{grant}'s real value sent to #{destination}: the VM holds it. Replace it at its service"
      end

    host = if how in [:request, :plaintext, :echo], do: destination
    {watch, [{:real_value, {grant, how}, summary, host, nil}]}
  end

  defp sense(firewall, watch, {:command, text}, _now) do
    # Quotes and backslashes a shell drops between the letters of a path
    # (`.ss""h`, `.ss\\h`) are dropped here too, so they hide nothing.
    folded = text |> String.downcase() |> String.replace(~r/["'\\`]/, "")

    case Enum.find(firewall.protected, &String.contains?(folded, String.downcase(&1))) do
      nil ->
        {watch, []}

      path ->
        {watch,
         [
           {:secret_paths, path, "A command the agent wrote names #{path}, a protected path", nil,
            nil}
         ]}
    end
  end

  defp sense(_firewall, watch, {:declined, key}, now),
    do: {put_in(watch.declined[key], {now, 0}), []}

  defp sense(_firewall, watch, {:ask, key, what}, now) do
    case watch.declined do
      %{^key => {at, asks}} when now - at < @declined_for ->
        watch = put_in(watch.declined[key], {at, asks + 1})

        if asks + 1 >= @asks_again,
          do:
            {watch,
             [
               {:asks_after_decline, key,
                "Asked #{asks + 1} times more for #{what} after you declined", nil, nil}
             ]},
          else: {watch, []}

      _not_declined ->
        {watch, []}
    end
  end

  defp sense(_firewall, watch, :read, now) do
    reads = [now | Enum.filter(watch.reads, &(now - &1 < @reads_window))] |> Enum.take(@reads * 2)
    watch = %{watch | reads: reads}

    if length(reads) >= @reads,
      do:
        {watch,
         [{:bulk_reads, :reads, "#{length(reads)} reads of your notes in 10 minutes", nil, nil}]},
      else: {watch, []}
  end

  defp sense(_firewall, watch, {:processes, processes}, now) do
    busy =
      for %{pid: pid, name: name, cpu: cpu} <- processes,
          is_number(cpu) and cpu >= @cpu_share,
          into: %{},
          do: {{pid, name}, Map.get(watch.cpu, {pid, name}, now)}

    seen =
      for {{pid, name}, since} <- busy, now - since >= @cpu_for do
        minutes = div(now - since, @minute)
        {:cpu_hog, {pid, name}, "#{name} (pid #{pid}) at a full CPU for #{minutes} min", nil, nil}
      end

    {%{watch | cpu: busy}, seen}
  end

  defp sense(_firewall, watch, _unknown, _now), do: {watch, []}

  # Names shaped to carry data: a long label or a long part before the
  # domain (refused; a few under one domain isolate), many names under one
  # domain, or many bytes of them. Names under a provider's own domain,
  # whose DNS no customer reads, carry nothing to anyone; nor does the
  # reverse name of an IPv4 address.
  defp names(watch, name, domain, now) do
    if domain == name or provider?(name) or reverse_v4?(name) do
      {watch, []}
    else
      before = String.trim_trailing(String.replace_suffix(name, domain, ""), ".")
      longest = before |> String.split(".") |> Enum.map(&byte_size/1) |> Enum.max()

      long =
        cond do
          longest >= @long_label -> "A label of #{longest} characters in #{name}"
          byte_size(before) >= @long_name -> "#{byte_size(before)} characters before #{domain}"
          true -> nil
        end

      {watch, long} = long_names(watch, name, domain, long, now)

      names =
        watch.names
        |> Map.get(domain, [])
        |> Enum.filter(fn {at, _} -> now - at < @names_window end)
        |> then(&[{now, name} | Enum.reject(&1, fn {_, seen} -> seen == name end)])
        |> Enum.take(@names_per_domain * 3)

      watch = put_in(capped_window(watch, :names).names[domain], names)

      bytes =
        names
        |> Enum.map(fn {_, seen} -> byte_size(seen) - byte_size(domain) - 1 end)
        |> Enum.sum()

      many =
        cond do
          length(names) > @names_per_domain ->
            [
              {:dns_tunnel, domain, "#{length(names)} names under #{domain} in 10 minutes",
               domain, nil}
            ]

          bytes >= @names_bytes ->
            [
              {:dns_tunnel, domain, "#{bytes} bytes of names under #{domain} in 10 minutes",
               domain, nil}
            ]

          true ->
            []
        end

      {watch, long ++ many}
    end
  end

  # A long name alone is refused; a few under one domain in 10 minutes
  # do what the rule says.
  defp long_names(watch, _name, _domain, nil, _now), do: {watch, []}

  defp long_names(watch, name, domain, summary, now) do
    long =
      watch
      |> Map.get(:long, %{})
      |> Map.get(domain, [])
      |> Enum.filter(fn {at, _} -> now - at < @names_window end)
      |> then(&[{now, name} | Enum.reject(&1, fn {_, seen} -> seen == name end)])
      |> Enum.take(@long_names * 2)

    watch = Map.update(watch, :long, %{domain => long}, &Map.put(&1, domain, long))

    if length(long) >= @long_names,
      do:
        {watch,
         [
           {:dns_tunnel, domain, "#{length(long)} long names under #{domain} in 10 minutes",
            domain, nil}
         ]},
      else: {watch, [{:dns_tunnel, domain, summary, domain, nil, :block}]}
  end

  # Many distinct addresses on one non-web port in a minute: a sweep for a
  # service (SSH, databases, RDP). Web ports are browsing and not counted;
  # connecting to one host many times isn't a sweep either.
  defp sweep(watch, _address, port, _now) when port in @web_ports, do: {watch, []}

  defp sweep(watch, address, port, now) do
    addresses =
      watch
      |> Map.get(:sweep, %{})
      |> Map.get(port, [])
      |> Enum.filter(fn {at, _} -> now - at < @scan_window end)
      |> then(&[{now, address} | Enum.reject(&1, fn {_, seen} -> seen == address end)])
      |> Enum.take(@sweep_addresses * 2)

    watch = put_in(capped_window(watch, :sweep).sweep[port], addresses)

    if length(addresses) >= @sweep_addresses,
      do:
        {watch,
         [
           {:scanning, {:sweep, port},
            "#{length(addresses)} addresses on port #{port} in a minute", address, port}
         ]},
      else: {watch, []}
  end

  # What uploads to a name are counted under: its domain, so that
  # `a.x.example` and `b.x.example` share a window. An address is itself.
  defp upload_key(destination) do
    if address?(destination), do: destination, else: domain(destination)
  end

  # The names, addresses and destinations are the VM's to make up: a window
  # starts over before it holds more than `@watched` of them, between the
  # sweeps that drop what is old (`prune/2`).
  defp capped_window(watch, key) do
    if map_size(Map.fetch!(watch, key)) >= @watched,
      do: Map.put(watch, key, %{}),
      else: watch
  end

  @doc """
  The domain a name is under: its last two labels, or three under a
  country's second level (`example.co.uk`). A reverse name is under its
  zone: an IPv4 address's /24, an IPv6 address's /48.

      iex> MWTClient.Sandbox.Firewall.domain("a.b.example.com")
      "example.com"

      iex> MWTClient.Sandbox.Firewall.domain("www.example.co.uk")
      "example.co.uk"

      iex> MWTClient.Sandbox.Firewall.domain("data.abc.io")
      "abc.io"

      iex> MWTClient.Sandbox.Firewall.domain("7.2.0.192.in-addr.arpa")
      "2.0.192.in-addr.arpa"
  """
  def domain(name) do
    labels = String.split(name, ".")

    case Enum.reverse(labels) do
      ["arpa", "in-addr" | octets] when octets != [] ->
        labels |> Enum.drop(1) |> Enum.join(".")

      ["arpa", "ip6" | nibbles] when length(nibbles) > 12 ->
        labels |> Enum.take(-14) |> Enum.join(".")

      [top, second, third | _] when byte_size(top) == 2 and second in @second_levels ->
        Enum.join([third, second, top], ".")

      [top, second | _] ->
        second <> "." <> top

      _one ->
        name
    end
  end

  # Under one of these, a name's DNS is the provider's: a customer chooses
  # the name, never reads the questions asked about it.
  defp provider?(name), do: listed?(name, @providers)

  # The reverse name of an IPv4 address: at most four numbers, before
  # in-addr.arpa. It carries a byte or so.
  defp reverse_v4?(name) do
    case name |> String.split(".") |> Enum.reverse() do
      ["arpa", "in-addr" | octets] when length(octets) in 1..4 ->
        Enum.all?(octets, &(&1 =~ ~r/\A(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\z/))

      _other ->
        false
    end
  end

  defp port_words(port) when port in [25, 465, 587, 2525], do: "a mail port"
  defp port_words(port) when port in [6667, 6697], do: "an IRC port"
  defp port_words(_port), do: "a Tor port"

  @doc false
  def size(bytes) when bytes >= @mib, do: "#{Float.round(bytes / @mib, 1)} MiB"
  def size(bytes) when bytes >= @kib, do: "#{div(bytes, @kib)} KiB"
  def size(bytes), do: "#{bytes} B"

  @doc "The rules, their ids as strings, for what the pages send."
  def rule_ids, do: @rule_ids
end
