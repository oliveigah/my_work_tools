defmodule MWTClient.Sandbox.Proposal do
  @moduledoc """
  What an agent proposes with `mwt propose`, turned into the fields of the
  form you would add it with, so MWT checks it exactly as it checks what
  you type (`MWTClient.Sandbox.Server.Grants.build_grant/3`). It proposes
  as you add things: a resource first, then grants over it.

  What an agent may propose (`target/3`):

    * a **credential** (`mwt propose credential`): the service it is for,
      how its value is made, how tools in the VM find its placeholder, and
      what its adapter takes. Never its value: you paste it whenever you
      have it;
    * a **network** (`mwt propose network`): its destinations, the DNS
      server for their names and the interface they are reached through;
    * a **grant** over a resource (`mwt propose grant --over RESOURCE`): a
      credential's (where its value may go, in which headers, what it
      narrows by, the accounts MWT signs as for it) or a network's (all
      of it, or the destinations it lists). Its resource may be one still
      to review: you accept the resource first;
    * an **action** over a resource that takes them: a saved command over
      your machine (`mwt propose machine`, or `commands` as before), a
      request action over a credential (`mwt propose CREDENTIAL`).

  Each starts from a preset of what it makes, when it names one
  (`--preset`); the options it gives (`--host`, `--mint`, …) set their
  fields over the preset's, and `--set FIELD=VALUE` any field of the form
  over both (`MWTClient.Sandbox.FormFields`); `--fill NAME=VALUE` fills the
  preset's blanks. None of the fields that are yours: a value, a start
  setting, an approval mode. MWT saves what it proposes at once, marked
  as proposed and to review.

  Pure: what the agent sent, what it names and the preset it starts from
  go in; the form's fields come out.
  """

  alias MWTClient.Sandbox.{FormFields, Grant}

  # What names your machine, for a saved command: `commands` was Ask to
  # run commands' id, which saved commands sat under.
  @machine ["machine", "commands", "any-command"]

  @typedoc "What a proposal makes, and over which resource."
  @type target ::
          {:new, :credential | :network}
          | {:grant, MWTClient.Sandbox.Resource.id(), map()}
          | {:over, MWTClient.Sandbox.Resource.id(), map()}

  @doc """
  What `wanted`, the word after `mwt propose`, names, with `over`, what
  `--over` names, for a grant: a new resource (`credential`, `network`), a
  grant over a resource, or the resource an action goes over: your
  machine (`machine`, or `commands` as before) for a saved command, a
  credential for a request action. A resource is named by its id or its
  name, in any case; a credential also by a token grant over it. `known`
  holds the `grants`, `credentials` and `networks` there are. The resource
  comes with what a grant or action takes from it: its name, and the
  headers a request starts from.

      iex> alias MWTClient.Sandbox.Proposal
      iex> Proposal.target("network", nil, %{})
      {:new, :network}
      iex> Proposal.target("commands", nil, %{})
      {:over, :machine, %{name: "Host commands", request_headers: nil}}
      iex> Proposal.target("token", nil, %{})
      {:error, :token_split}
      iex> Proposal.target("grant", "internet", %{networks: [%{id: "internet", name: "Internet"}]})
      {:grant, {:network, "internet"}, %{name: "Internet", request_headers: nil}}
      iex> Proposal.target("nothing", nil, %{})
      {:error, :unknown_grant}
  """
  @spec target(String.t(), String.t() | nil, map()) :: target() | {:error, term()}
  def target(wanted, over, known) do
    cond do
      wanted in ["credential", "network"] ->
        {:new, String.to_existing_atom(wanted)}

      wanted == "grant" ->
        grant_target(over, known)

      # A credential and a grant over it in one, until 2026-11-25.
      wanted == "token" ->
        {:error, :token_split}

      String.downcase(wanted) in @machine ->
        {:over, :machine, %{name: "Host commands", request_headers: nil}}

      true ->
        case credential(wanted, known) do
          nil -> action_target_error(wanted, known)
          credential -> {:over, {:credential, credential.id}, over_info(credential)}
        end
    end
  end

  defp grant_target(over, known) do
    over = text(over)

    cond do
      over == "" ->
        {:error, :no_over}

      network = named(Map.get(known, :networks, []), over) ->
        {:grant, {:network, network.id}, %{name: network.name, request_headers: nil}}

      credential = credential(over, known) ->
        {:grant, {:credential, credential.id}, over_info(credential)}

      String.downcase(over) in @machine ->
        {:error, {:no_grants, "Host commands"}}

      true ->
        {:error, {:unknown_resource, over}}
    end
  end

  defp action_target_error(wanted, known) do
    case named(Map.get(known, :networks, []), wanted) ||
           Enum.find(Map.get(known, :grants, []), &(&1.id == wanted)) do
      nil -> {:error, :unknown_grant}
      named -> {:error, {:no_actions, named.name}}
    end
  end

  # A credential by its id or name, or by a token grant over it (as an
  # agent knew it before credentials were apart).
  defp credential(wanted, known) do
    credentials = Map.get(known, :credentials, [])

    named(credentials, wanted) ||
      with %{} = grant <-
             Enum.find(
               Map.get(known, :grants, []),
               &(&1.kind == :token and
                   (&1.id == wanted or String.downcase(&1.name) == String.downcase(wanted)))
             ) do
        Enum.find(credentials, &(&1.id == Grant.credential_id(grant))) ||
          %{
            id: Grant.credential_id(grant),
            name: Grant.credential_id(grant),
            request_headers: grant.request_headers
          }
      end
  end

  defp named(resources, wanted) do
    Enum.find(resources, &(&1.id == wanted)) ||
      Enum.find(resources, &(String.downcase(&1.name) == String.downcase(wanted)))
  end

  defp over_info(credential),
    do: %{name: credential.name, request_headers: Map.get(credential, :request_headers)}

  @doc """
  The thing `target` makes (`MWTClient.Sandbox.FormFields`), whose fields
  `--set` may set.

      iex> MWTClient.Sandbox.Proposal.thing({:grant, {:credential, "gh"}, %{}})
      :credential_grant
  """
  @spec thing(target()) :: FormFields.thing()
  def thing({:new, :credential}), do: :credential
  def thing({:new, :network}), do: :network
  def thing({:grant, {:credential, _id}, _over}), do: :credential_grant
  def thing({:grant, {:network, _id}, _over}), do: :network_grant
  def thing({:over, {:credential, _id}, _over}), do: :request_action
  def thing({:over, :machine, _over}), do: :command_action

  @doc """
  What a preset must make to start `target`'s form: `:credential`,
  `:network`, `:grant` or `:command`; nil for a request action, which no
  preset starts.
  """
  @spec preset_makes(target()) :: atom() | nil
  def preset_makes({:new, :credential}), do: :credential
  def preset_makes({:new, :network}), do: :network
  def preset_makes({:grant, {:credential, _id}, _over}), do: :grant
  def preset_makes({:over, :machine, _over}), do: :command
  def preset_makes(_target), do: nil

  @things [
    :credential,
    :credential_grant,
    :network,
    :network_grant,
    :request_action,
    :command_action
  ]

  # The options that set a field, by the field they set, and the thing
  # whose field it is: one given for another thing is refused, never
  # dropped.
  @options [
    {:hosts, "hosts", "--host"},
    {:env, "env", "--env"},
    {:file_env, "file_env", "--file-env"},
    {:carriers, "carriers", "--carrier"},
    {:git, "git", "--git"},
    {:mint, "mint", "--mint"},
    {:keep_minutes, "keep_minutes", "--keep-minutes"},
    {:signs_as, "signs_as", "--sign-as"},
    {:login_file, "present_login", "--login-file"},
    {:id_token_header, "present_id_header", "--id-token-header"},
    {:metadata_project, "present_project", "--metadata-project"},
    {:metadata_account, "present_email", "--metadata-account"},
    {:destinations, "destinations", "--destination"},
    {:resolver, "resolver", "--resolver"},
    {:anchor, "anchor", "--via"},
    {:script, "script", "the script"},
    {:dir, "dir", "--dir"},
    {:params, "params", "--param"},
    {:method, "method", "--method"},
    {:url, "url", "--url"},
    {:headers, "headers", "--header"},
    {:body, "body", "--data"}
  ]

  @doc """
  The form's fields for what the agent proposes: `ask` is what it sent
  (`name`, `purpose`, the options of its kind, `set` and `fill`), `preset`
  the preset it starts from, if any. The preset's fields first, the
  options' over them, then `set`'s over both. `{:ok, attrs}`, or why not:
  an option or a field `target`'s thing doesn't have, or one of yours.

      iex> alias MWTClient.Sandbox.Proposal
      iex> {:ok, attrs} = Proposal.attrs({:new, :credential},
      ...>   %{name: "App", purpose: "My App", mint: "cat key.pem",
      ...>     set: %{"adapter" => "github", "app_id" => "Iv23li", "installation_id" => "42"}}, nil)
      iex> Map.take(attrs, ~w(adapter app_id installation_id source mint))
      %{"adapter" => "github", "app_id" => "Iv23li", "installation_id" => "42",
        "source" => "minted", "mint" => "cat key.pem"}
      iex> Proposal.attrs({:new, :credential}, %{name: "x", purpose: "y", hosts: ["a.example"]}, nil)
      {:error, "--host isn't for a credential: it sets hosts, a field of a grant over a credential. Its fields: name, purpose, adapter, source, mint, mint_per, keep_minutes, prefix, env, file_env, git, app_id, installation_id, present_metadata, present_project, present_email, present_login, present_id_header."}
  """
  @spec attrs(target(), map(), map() | nil) :: {:ok, map()} | {:error, String.t()}
  def attrs(target, ask, preset) do
    thing = thing(target)
    set = Map.new(Map.get(ask, :set) || %{}, fn {key, value} -> {to_string(key), text(value)} end)

    with {:ok, options} <- options(thing, ask),
         :ok <- FormFields.check(thing, set) do
      attrs =
        preset_fields(preset)
        |> Map.merge(base(target, ask, preset))
        |> Map.merge(options)
        |> Map.merge(set)
        |> derived()
        |> defaults(target)
        |> Map.put(
          "fill",
          Map.new(Map.get(ask, :fill) || %{}, fn {k, v} -> {to_string(k), text(v)} end)
        )

      {:ok, attrs}
    end
  end

  # What every proposal of a target carries, whatever the agent gave.
  defp base({:new, :credential}, ask, preset) do
    given(%{"name" => text(ask[:name]), "purpose" => text(ask[:purpose])})
    |> Map.merge(%{
      "kind" => "token",
      "preset" => preset && to_string(preset.id),
      # A credential is a token grant's form with no scope of its own
      # (`MWTClient.Sandbox.Server.Resources`).
      "hosts" => "credential.invalid"
    })
  end

  defp base({:new, :network}, ask, preset) do
    given(%{"name" => text(ask[:name]), "purpose" => text(ask[:purpose])})
    |> Map.merge(%{"kind" => "network", "preset" => preset && to_string(preset.id)})
  end

  defp base({:grant, {:credential, id}, _over}, ask, preset) do
    given(%{"name" => text(ask[:name]), "purpose" => text(ask[:purpose])})
    |> Map.merge(%{
      "kind" => "token",
      "credential" => id,
      "preset" => preset && to_string(preset.id)
    })
  end

  defp base({:grant, {:network, id}, _over}, ask, _preset) do
    given(%{"name" => text(ask[:name]), "purpose" => text(ask[:purpose])})
    |> Map.merge(%{"kind" => "network", "network" => id})
  end

  defp base({:over, {:credential, id}, over}, ask, _preset) do
    headers = ask[:headers] |> List.wrap() |> lines()

    given(%{"name" => text(ask[:name]), "purpose" => text(ask[:purpose])})
    |> Map.merge(%{
      "kind" => "request",
      "credential" => id,
      "method" =>
        if(text(ask[:method]) == "", do: "GET", else: String.upcase(text(ask[:method]))),
      "headers" =>
        if(headers == "",
          do: over.request_headers || MWTClient.Sandbox.SavedRequest.default_headers(nil),
          else: headers
        )
    })
  end

  defp base({:over, :machine, _over}, ask, preset) do
    given(%{"name" => text(ask[:name]), "purpose" => text(ask[:purpose])})
    |> Map.merge(%{
      "kind" => "command",
      "preset" => (preset && to_string(preset.id)) || "saved_command",
      # Confined, as an action you add starts: nothing of your keys or
      # logins in reach until you choose otherwise as you review it.
      "confined" => "true"
    })
  end

  # The fields the agent's options set, each checked against the thing's.
  defp options(thing, ask) do
    fields = FormFields.of(thing)

    Enum.reduce_while(@options, {:ok, %{}}, fn {key, field, option}, {:ok, acc} ->
      value = option_value(key, ask)

      cond do
        value == "" ->
          {:cont, {:ok, acc}}

        field in fields ->
          {:cont, {:ok, Map.put(acc, field, value)}}

        true ->
          owner = Enum.find(@things, &(field in FormFields.of(&1)))

          {:halt,
           {:error,
            "#{option} isn't for #{FormFields.name(thing)}: it sets #{field}, a field of " <>
              "#{FormFields.name(owner)}. Its fields: #{Enum.join(fields, ", ")}."}}
      end
    end)
  end

  defp option_value(:git, ask), do: if(ask[:git] == true, do: "true", else: "")
  defp option_value(:login_file, ask), do: if(ask[:login_file] == true, do: "true", else: "")

  defp option_value(key, ask) when key in [:hosts, :env, :file_env, :carriers, :signs_as],
    do: joined(ask[key])

  # A request action's headers are its base's: its credential's when it
  # gives none.
  defp option_value(:headers, _ask), do: ""
  defp option_value(:method, ask), do: ask[:method] |> text() |> String.upcase()

  defp option_value(key, ask) when key in [:destinations, :params],
    do: ask[key] |> List.wrap() |> lines()

  defp option_value(:script, ask),
    do: ask[:script] |> text() |> String.replace("\r\n", "\n")

  defp option_value(key, ask), do: text(ask[key])

  # What a field implies as the form takes it: a mint command makes the
  # value minted; a metadata project or account asks for the metadata
  # server; a header for the ID token asks for the login it comes from.
  defp derived(attrs) do
    attrs
    |> then(&if(present?(&1["mint"]), do: Map.put_new(&1, "source", "minted"), else: &1))
    |> then(fn attrs ->
      if present?(attrs["present_project"]) or present?(attrs["present_email"]),
        do: Map.put_new(attrs, "present_metadata", "true"),
        else: attrs
    end)
    |> then(
      &if(present?(&1["present_id_header"]),
        do: Map.put_new(&1, "present_login", "true"),
        else: &1
      )
    )
  end

  defp defaults(attrs, {:new, :credential}),
    do: attrs |> Map.put_new("prefix", "mwt_") |> Map.put_new("source", "stored")

  defp defaults(attrs, _target), do: attrs

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc """
  Who proposed it, as the grant or resource keeps it (`Grant.proposal`):
  the agent, its thread, why, how long it asked for, and when; not
  reviewed yet. Its `revision` is new each time the agent proposes it, a
  changed one included: accepting names the revision the page showed, so
  one the agent changed between your reading and your click isn't
  accepted (`accepts?/2`).
  """
  @spec stamp(map(), DateTime.t()) :: Grant.proposal()
  def stamp(said, now) do
    %{
      agent: said.agent,
      thread: said.thread,
      reason: said.reason,
      minutes: said.minutes,
      at: now,
      reviewed_at: nil,
      revision: 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    }
  end

  @doc """
  Whether accepting from a page that showed `revision` accepts `proposal`
  as the agent last proposed it. A proposal saved before revisions has
  none, and a page showing it sends none.
  """
  @spec accepts?(Grant.proposal(), String.t() | nil) :: boolean()
  def accepts?(proposal, revision),
    do: to_string(Map.get(proposal, :revision)) == to_string(revision)

  @order [
    :kind,
    :name,
    :purpose,
    :adapter,
    :app,
    :hosts,
    :env,
    :carriers,
    :mint,
    :keep_minutes,
    :signs_as,
    :present_project,
    :present_email,
    :present_login,
    :present_id_header,
    :destinations,
    :resolver,
    :anchor,
    :script,
    :dir,
    :params,
    :method,
    :url,
    :headers,
    :body,
    :fill
  ]

  @doc """
  What the agent hears when its proposal is refused, from the form's
  errors by field: each, with the option it comes from, in the order the
  help gives them.
  """
  @spec refusal(%{atom() => String.t()}) :: String.t()
  def refusal(errors) do
    errors
    |> Enum.sort_by(fn {field, _} -> Enum.find_index(@order, &(&1 == field)) || 99 end)
    |> Enum.map_join(" ", fn {field, message} -> "#{option(field)}#{message}" end)
  end

  defp option(:name), do: "--name: "
  defp option(:purpose), do: "--for: "
  defp option(:fill), do: "--fill: "
  defp option(:adapter), do: "--set adapter: "
  defp option(:app), do: "--set app_id, installation_id: "
  defp option(:present_login), do: "--login-file: "

  defp option(field) do
    case Enum.find(@options, fn {_key, name, _option} -> name == Atom.to_string(field) end) do
      {_key, _name, "the script"} -> "the script: "
      {_key, _name, option} -> option <> ": "
      nil -> "--set #{field}: "
    end
  end

  # A preset's fields, as its form starts from them.
  defp preset_fields(nil), do: %{}
  defp preset_fields(%{fields: fields}), do: fields

  # Only what the agent gave overrides the preset.
  defp given(fields), do: Map.reject(fields, fn {_key, value} -> value == "" end)

  defp joined(values), do: values |> List.wrap() |> Enum.map(&text/1) |> Enum.join(", ")
  defp lines(values), do: values |> Enum.map(&text/1) |> Enum.join("\n")

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_other), do: ""
end
