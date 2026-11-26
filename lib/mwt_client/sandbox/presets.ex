defmodule MWTClient.Sandbox.Presets do
  @moduledoc """
  What the add dialogs offer: the types, and presets that fill a form for
  services whose details are known. A command grant is a saved command,
  your own script (`:saved_command`); a command an agent writes goes under
  Commands agents write (`:agent_commands`), built in.

  A preset is a JSON file (since 2026-11-17): MWT's own under
  `priv/sandbox/presets/`, yours in the identity's folder (`dir/1`). Each
  says what it `makes` (since 2026-11-25), as you add things: a resource
  first, then grants over it.

    * `credential` - a credential's form: the service it is for
      (`adapter`), how its value is made, how tools find it, the request
      headers its actions start from and the tools it serves;
    * `grant` - a grant over a credential: where its value goes, what it
      narrows by, and the actions it adds beside it. `over` lists the
      adapters and credential presets it is for; none, any credential;
    * `network` - a network's form; `command` - a saved command's.

  Its `fields` are the form's (`MWTClient.Sandbox.FormFields`), with fields
  of yours to fill first (`fill`, each `{name}` in them). Everything it
  gives is copied onto what it makes: nothing in MWT looks at which preset
  made it again, but the grant presets offered over a credential, by the
  preset it came from.

  A file written before 2026-11-25 has a `kind` and a `grant` object, a
  credential and a grant in one: it is read as a credential preset under
  its id and a grant preset over it (`ID-grant`), each with the fields of
  its own.

  The VM-side details come from the checks of 2026-11-11: `gh` sends
  `Authorization: token`, git sends the token as the Basic password after a
  401, Hex sends the whole header value, gcloud reads a bearer token from the
  file `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` names.
  """
  @typedoc """
  A type or a preset. `fields` are the form's params it starts from
  (`MWTClient.Sandbox.FormFields`). A preset says what it `makes`, and a
  grant preset which credentials it is `over`.
  """
  @type t :: %{
          required(:id) => atom() | String.t(),
          optional(:makes) => :credential | :grant | :network | :command,
          optional(:over) => [String.t()],
          optional(atom()) => term(),
          required(:kind) => MWTClient.Sandbox.Grant.kind(),
          required(:name) => String.t(),
          required(:icon) => String.t(),
          required(:blurb) => String.t(),
          required(:guide) => [String.t()],
          required(:fields) => %{String.t() => String.t()}
        }

  @types [
    %{
      id: :token,
      kind: :token,
      name: "Token or API key",
      icon: "hero-key",
      blurb: "A secret sent in HTTP requests: API keys, bearer tokens, git over HTTPS.",
      guide: [
        "Create the token as restricted and short-lived as the service allows.",
        "List the hosts it is sent to. The VM gets a placeholder; MWT swaps in the real value only on requests to these hosts.",
        "Name the variables the tool reads (STRIPE_API_KEY, say). MWT swaps the real value into the Authorization header only, Basic credentials included; name other headers under More ways the VM gets it."
      ],
      fields: %{"source" => "stored", "prefix" => "mwt_"}
    },
    %{
      id: :network,
      kind: :network,
      name: "Network access",
      icon: "hero-signal",
      blurb: "Hosts and address ranges behind your VPN or on your network.",
      guide: [
        "Connect your VPN on this machine as usual.",
        "List what the VM may reach, one per line: 10.20.0.0/16:443,5432 or git.corp.internal:443.",
        "Each connection waits for your approval unless you allow them for a while."
      ],
      fields: %{}
    },
    %{
      id: :saved_command,
      kind: :command,
      name: "Saved command",
      icon: "hero-bookmark-square",
      blurb:
        "Your own script, in your folder, run on your machine. Agents call it by id, and send no text.",
      guide: [
        "Write the script as you would type it. Agents can run only this text, in the folder you name, and send nothing of their own.",
        "What varies between calls is a parameter: the script reads it as a variable, \"$NAME\", and an agent gives a value of the shape you set. Keep them few, and each as narrow as works.",
        "It has a switch of its own: on for a time or on startup, asking each time or auto-approved.",
        "Keep it small: let it fetch what the agent needs, and let the agent do the rest in the VM."
      ],
      fields: %{}
    },
    %{
      id: :mwt,
      kind: :mwt,
      name: "MWT's tools",
      icon: "hero-squares-2x2",
      blurb:
        "Built in: agents in the VM read, add and change your notes, diagrams, flash cards and HTTP samples in MWT.",
      guide: [
        "Agents reach them with mwt mcp, an MCP server MWT registers with Claude Code and Codex in the VM. Nothing in the VM holds a token for them.",
        "Three grants, each enabled on startup: reading and adding auto-approved; changing what exists asks, showing every change as a diff for you to allow.",
        "Every change keeps what it replaced as a version: restore it from the item's Versions."
      ],
      fields: %{}
    },
    %{
      id: :agent_commands,
      kind: :agent_commands,
      name: "Commands agents write",
      icon: "hero-command-line",
      blurb:
        "Built in: agents ask to run a command they write on your machine, and you approve every run.",
      guide: [
        "An agent sends the text with mwt run, and you read it on a card before anything runs.",
        "Every run waits for you: no setting lets one through unasked. Off, agents can't ask.",
        "It is handed no credential's value: a command that needs one is a saved command."
      ],
      fields: %{}
    },
    %{
      id: :request_action,
      kind: :request,
      name: "Fixed request",
      icon: "hero-paper-airplane",
      blurb:
        "One request MWT sends itself with its credential's real value. Agents call it by id, and send only values.",
      guide: [
        "Write the request: the method, and the URL to a host the grant lists. What varies between calls is a parameter, $NAME, in the path or the query, or as a whole value in the JSON body.",
        "Headers are fixed. {token} stands for the real value, where the service takes it. MWT sends it itself, so the VM needs no tool and no placeholder.",
        "It has a switch of its own: on for a time or on startup, asking each time or auto-approved, while open use of the credential stays off. Every call shows the exact request on its card, unless you let it through."
      ],
      fields: %{}
    }
  ]

  @doc "The grant types, in the order the add dialog shows them."
  @spec types() :: [t()]
  def types, do: @types

  @doc """
  The presets, in the order the add dialog shows them: MWT's own
  (`priv/sandbox/presets/*.json`), then yours, from the identity's folder
  (`sandbox/presets/*.json`) when `username` is given. A file that can't be
  read is left out; `load/1` says why.
  """
  @spec presets(String.t() | nil) :: [t()]
  def presets(username \\ nil) do
    {own, _errors} = load(own_dir())

    yours =
      case username do
        nil -> []
        username -> username |> dir() |> load() |> elem(0) |> Enum.map(&Map.put(&1, :yours, true))
      end

    ids = MapSet.new(own, & &1.id)
    own ++ Enum.reject(yours, &MapSet.member?(ids, &1.id))
  end

  @doc "Where MWT's own presets are."
  def own_dir, do: Path.join([:code.priv_dir(:mwt_client), "sandbox", "presets"])

  @doc "Where an identity keeps presets of its own."
  def dir(username), do: Path.join([MWTClient.Accounts.dir(username), "sandbox", "presets"])

  @doc """
  The presets in `dir`, one a JSON file, and each file that isn't one, with
  why.
  """
  @spec load(Path.t()) :: {[t()], [{Path.t(), String.t()}]}
  def load(dir) do
    files = dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

    Enum.reduce(files, {[], []}, fn path, {presets, errors} ->
      with {:ok, text} <- File.read(path),
           {:ok, json} <- decode(text),
           {:ok, read} <- read(json) do
        {presets ++ read, errors}
      else
        {:error, reason} when is_binary(reason) -> {presets, errors ++ [{path, reason}]}
        {:error, reason} -> {presets, errors ++ [{path, inspect(reason)}]}
      end
    end)
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, _other} -> {:error, "it isn't a JSON object"}
      {:error, error} -> {:error, "it isn't JSON: " <> Exception.message(error)}
    end
  end

  @kinds %{"token" => :token, "network" => :network, "command" => :command}
  @makes %{
    "credential" => {:credential, :token, :credential},
    "grant" => {:grant, :token, :credential_grant},
    "network" => {:network, :network, :network},
    "command" => {:command, :command, :command_action}
  }
  @id ~r/\A[a-z0-9][a-z0-9-]{0,40}\z/
  @fill ~r/\A[a-z][a-z0-9_]{0,30}\z/

  @doc """
  The presets a file holds, or what is wrong with it: one, or two from a
  file written before presets said what they make (a credential and a
  grant over it).

      iex> alias MWTClient.Sandbox.Presets
      iex> {:ok, [preset]} = Presets.read(%{"id" => "acme", "makes" => "credential",
      ...>   "adapter" => "bearer", "name" => "Acme", "fields" => %{"env" => "ACME_KEY"}})
      iex> {preset.id, preset.makes, preset.fields}
      {"acme", :credential, %{"adapter" => "bearer", "env" => "ACME_KEY"}}
      iex> {:ok, [credential, grant]} = Presets.read(%{"id" => "acme", "kind" => "token",
      ...>   "name" => "Acme", "grant" => %{"hosts" => "api.acme.test", "env" => "ACME_KEY"}})
      iex> {credential.fields, grant.id, grant.over, grant.fields}
      {%{"adapter" => "bearer", "env" => "ACME_KEY"}, "acme-grant", ["acme"], %{"hosts" => "api.acme.test"}}
      iex> Presets.read(%{"id" => "x", "makes" => "grant", "name" => "X", "fields" => %{"value" => "v"}})
      {:error, "value is yours to set, as you review it."}
      iex> Presets.read(%{"id" => "x", "kind" => "rocket", "name" => "X", "grant" => %{}})
      {:error, "makes is one of credential, grant, network, command"}
  """
  @spec read(map()) :: {:ok, [t()]} | {:error, String.t()}
  def read(json) do
    fill = List.wrap(json["fill"])
    legacy? = not Map.has_key?(json, "makes") and Map.has_key?(json, "kind")

    cond do
      not (is_binary(json["id"]) and json["id"] =~ @id) ->
        {:error, "id is lowercase letters, digits and dashes"}

      json["id"] in Enum.map(@types, &Atom.to_string(&1.id)) ->
        {:error, "id #{json["id"]} is a type's"}

      not (Map.has_key?(@makes, json["makes"]) or
               (legacy? and Map.has_key?(@kinds, json["kind"]))) ->
        {:error, "makes is one of credential, grant, network, command"}

      not (is_binary(json["name"]) and String.trim(json["name"]) != "") ->
        {:error, "it needs a name"}

      not is_map(if(legacy?, do: json["grant"], else: json["fields"] || %{})) ->
        {:error, "fields is an object of the form's fields"}

      not Enum.all?(fill, &(is_map(&1) and is_binary(&1["name"]) and &1["name"] =~ @fill)) ->
        {:error, "each field to fill has a name: lowercase letters, digits and underscores"}

      Enum.any?(fill, &(&1["name"] == "token")) ->
        {:error, "{token} stands for the real value: name the field otherwise"}

      legacy? ->
        {:ok, legacy(json)}

      true ->
        {makes, _kind, thing} = @makes[json["makes"]]
        fields = Map.new(json["fields"] || %{}, fn {key, value} -> {key, field(value)} end)

        with :ok <- MWTClient.Sandbox.FormFields.check(thing, fields),
             {:ok, adapter} <- preset_adapter(makes, json["adapter"]) do
          fields = if adapter, do: Map.put(fields, "adapter", adapter), else: fields
          {:ok, [made(json, makes, fields)]}
        end
    end
  end

  # A credential preset's adapter: one MWT has, `bearer` when it names none.
  defp preset_adapter(:credential, nil), do: {:ok, "bearer"}

  defp preset_adapter(:credential, id) do
    case MWTClient.Sandbox.Adapter.find(id) do
      {:ok, adapter} -> {:ok, Atom.to_string(adapter.id())}
      :error -> {:error, "adapter is one of #{adapter_ids()}"}
    end
  end

  defp preset_adapter(_makes, _id), do: {:ok, nil}

  defp adapter_ids,
    do: Enum.map_join(MWTClient.Sandbox.Adapter.all(), ", ", &Atom.to_string(&1.id()))

  # A file written before presets said what they make: a token one is a
  # credential and a grant over it, each with its own fields of the old
  # form's; a network or command one makes what it says.
  defp legacy(json) do
    fields = Map.new(json["grant"], fn {key, value} -> {key, field(value)} end)

    case @kinds[json["kind"]] do
      :token ->
        alias MWTClient.Sandbox.FormFields

        credential_fields = Map.take(fields, FormFields.of(:credential))

        adapter =
          MWTClient.Sandbox.Adapter.of(%{
            preset: json["id"],
            app: if(fields["app_id"], do: %{}),
            signs_as: if(fields["signs_as"] not in [nil, ""], do: [fields["signs_as"]], else: []),
            presents: if(fields["present_login"] == "true", do: %{login: %{}}, else: %{})
          })

        credential =
          made(
            json,
            :credential,
            Map.put(credential_fields, "adapter", Atom.to_string(adapter.id()))
          )

        grant =
          made(
            Map.merge(json, %{"id" => json["id"] <> "-grant", "over" => [json["id"]]}),
            :grant,
            Map.take(fields, FormFields.of(:credential_grant))
          )

        [%{credential | actions: []}, %{grant | request_headers: nil, tools: []}]

      :network ->
        [made(json, :network, Map.take(fields, MWTClient.Sandbox.FormFields.of(:network)))]

      :command ->
        [
          made(
            json,
            :command,
            Map.take(fields, MWTClient.Sandbox.FormFields.of(:command_action))
          )
        ]
    end
  end

  defp made(json, makes, fields) do
    {_makes, kind, _thing} = Enum.find_value(@makes, fn {_k, v} -> elem(v, 0) == makes && v end)

    %{
      id: json["id"],
      makes: makes,
      kind: kind,
      name: String.trim(json["name"]),
      icon: text(json["icon"]) || type(kind).icon,
      blurb: text(json["blurb"]) || "",
      guide: Enum.filter(List.wrap(json["guide"]), &is_binary/1),
      fields: fields,
      fill:
        for(
          field <- List.wrap(json["fill"]),
          do: %{
            name: field["name"],
            label: text(field["label"]) || field["name"],
            example: text(field["example"]) || ""
          }
        ),
      over: if(makes == :grant, do: Enum.filter(List.wrap(json["over"]), &is_binary/1), else: []),
      request_headers: text(json["request_headers"]),
      tools: Enum.filter(List.wrap(json["tools"]), &is_binary/1),
      # `subgrants` in a preset written before actions were called so.
      actions: Enum.filter(List.wrap(json["actions"] || json["subgrants"]), &is_map/1)
    }
  end

  @doc """
  The presets that make `makes` (`:credential`, `:grant`, `:network`,
  `:command`), yours included when `username` is given.
  """
  @spec making(atom(), String.t() | nil) :: [t()]
  def making(makes, username \\ nil),
    do: Enum.filter(presets(username), &(Map.get(&1, :makes) == makes))

  @doc """
  What a preset sets, in a few words each, for choosing one without
  opening it: a credential preset's service, where its value comes from,
  how tools find it; a grant preset's hosts and what it narrows by. A
  blank of yours shows as what you give.

      iex> {:ok, preset} = MWTClient.Sandbox.Presets.find("github-app")
      iex> MWTClient.Sandbox.Presets.summary(preset)
      ["GitHub", "minted by a command you give", "GITHUB_TOKEN, GH_TOKEN", "git over HTTPS", "a GitHub App"]
      iex> {:ok, preset} = MWTClient.Sandbox.Presets.find("github-repository")
      iex> MWTClient.Sandbox.Presets.summary(preset)
      ["api.github.com +2", "only github.repository = the repository you give"]
  """
  @spec summary(t()) :: [String.t()]
  def summary(%{makes: :credential, fields: fields}) do
    adapter =
      case MWTClient.Sandbox.Adapter.find(fields["adapter"]) do
        {:ok, adapter} -> adapter.name()
        :error -> nil
      end

    [
      adapter,
      if(fields["source"] == "minted",
        do:
          if(blank?(fields["mint"]),
            do: "minted by a command you give",
            else: "minted by " <> fields["mint"]
          ),
        else: "a value you paste"
      ),
      present(fields["env"]),
      present(fields["file_env"]) && "a token file",
      fields["git"] == "true" && "git over HTTPS",
      fields["app_id"] && "a GitHub App",
      fields["present_login"] == "true" && "a Google login file"
    ]
    |> Enum.filter(&is_binary/1)
  end

  def summary(%{makes: :grant, fields: fields}) do
    hosts =
      fields["hosts"] |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    [
      case hosts do
        [] -> nil
        [one] -> one
        [first | rest] -> "#{first} +#{length(rest)}"
      end,
      present(fields["attributes"]) && "only " <> with_blanks(fields["attributes"])
    ]
    |> Enum.filter(&is_binary/1)
  end

  def summary(_preset), do: []

  @doc """
  What a preset asks you for before it can make anything: each blank's
  label (`fill`).
  """
  @spec needs(t()) :: [String.t()]
  def needs(preset), do: Enum.map(Map.get(preset, :fill, []), & &1.label)

  defp present(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp blank?(value), do: value |> to_string() |> String.contains?("{")

  defp with_blanks(text),
    do:
      Regex.replace(~r/\{([a-z_]+)\}/, text, fn _, name ->
        "the #{String.replace(name, "_", " ")} you give"
      end)

  @doc """
  The grant presets offered over `credential`: those for its adapter or
  the preset it came from, and those for any credential.

      iex> alias MWTClient.Sandbox.{Credential, Presets}
      iex> credential = %Credential{id: "gh", name: "GitHub", adapter: :github, preset: "github-app"}
      iex> credential |> Presets.over() |> Enum.map(& &1.id)
      ["github-everything", "github-repository"]
  """
  @spec over(MWTClient.Sandbox.Credential.t() | map(), String.t() | nil) :: [t()]
  def over(credential, username \\ nil), do: for_credential(presets(username), credential)

  @doc """
  The grant presets among `presets` offered over `credential` (`over/2`).
  """
  @spec for_credential([t()], MWTClient.Sandbox.Credential.t() | map()) :: [t()]
  def for_credential(presets, credential) do
    names = [to_string(Map.get(credential, :adapter)), to_string(Map.get(credential, :preset))]

    Enum.filter(
      presets,
      &(Map.get(&1, :makes) == :grant and
          (&1.over == [] or Enum.any?(&1.over, fn over -> over in names end)))
    )
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: nil

  defp field(value) when is_binary(value), do: value
  defp field(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp field(value) when is_list(value), do: Enum.map_join(value, ", ", &to_string/1)
  defp field(_other), do: ""

  @doc """
  `attrs`, a form's fields, with each `{name}` of the preset's fields to
  fill replaced by what the form gave for it (`attrs["fill"]`); or the
  first one missing.

      iex> MWTClient.Sandbox.Presets.fill(%{"hosts" => "{org}.acme.test", "fill" => %{"org" => "mine"}},
      ...>   [%{name: "org", label: "Org", example: ""}])
      {:ok, %{"hosts" => "mine.acme.test"}}
  """
  @spec fill(map(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def fill(attrs, fields) do
    given = Map.get(attrs, "fill") || %{}

    # Only a field still written somewhere must be filled: one you
    # replaced in the form needs nothing.
    used? = fn field ->
      Enum.any?(attrs, fn {_key, value} ->
        is_binary(value) and String.contains?(value, "{#{field.name}}")
      end)
    end

    case Enum.find(fields, &(used?.(&1) and String.trim(to_string(given[&1.name])) == "")) do
      nil ->
        filled =
          attrs
          |> Map.delete("fill")
          |> Map.new(fn
            {key, value} when is_binary(value) and key != "value" ->
              {key,
               Enum.reduce(fields, value, fn field, value ->
                 String.replace(
                   value,
                   "{" <> field.name <> "}",
                   String.trim(to_string(given[field.name]))
                 )
               end)}

            other ->
              other
          end)

        {:ok, filled}

      missing ->
        {:error, "Fill in #{missing.label}."}
    end
  end

  @doc """
  Whether `name` may name a preset file of yours: a plain JSON file name,
  no folder in it, nothing that reads as an option.

      iex> MWTClient.Sandbox.Presets.file_name?("github-app.json")
      true
      iex> MWTClient.Sandbox.Presets.file_name?("../x.json")
      false
  """
  @spec file_name?(String.t()) :: boolean()
  def file_name?(name) when is_binary(name),
    do:
      Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,80}\.json\z/, name) and
        not String.contains?(name, "..")

  def file_name?(_name), do: false

  @doc "Looks a type or preset up by the string a form sends, yours included when `username` is given."
  @spec find(String.t(), String.t() | nil) :: {:ok, t()} | :error
  def find(id, username \\ nil) when is_binary(id) do
    case Enum.find(@types ++ presets(username), &(to_string(&1.id) == id)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  @doc "The type itself, for a grant's kind."
  @spec type(MWTClient.Sandbox.Grant.kind()) :: t()
  def type(kind), do: Enum.find(@types, &(&1.kind == kind))

  @doc "A grant's own type."
  @spec type_of(MWTClient.Sandbox.Grant.t()) :: t()
  def type_of(%{kind: kind}), do: type(kind)

  @doc """
  What a grant's form is made from, to edit it: its own type. What a preset
  gave was copied onto the grant when it was made.
  """
  @spec type_or_preset(MWTClient.Sandbox.Grant.t()) :: t()
  def type_or_preset(grant), do: type_of(grant)

  @doc "The icon of a grant: its own, copied from the preset that made it, or its type's."
  @spec icon(MWTClient.Sandbox.Grant.t() | nil) :: String.t()
  def icon(nil), do: "hero-key"
  def icon(%{icon: icon}) when is_binary(icon), do: icon
  def icon(grant), do: type_of(grant).icon

  @doc "What a grant's type is called."
  @spec kind_name(MWTClient.Sandbox.Grant.kind()) :: String.t()
  def kind_name(kind), do: type(kind).name

  @doc "What a grant is, by its own type."
  @spec type_name(MWTClient.Sandbox.Grant.t()) :: String.t()
  def type_name(grant), do: type_of(grant).name
end
