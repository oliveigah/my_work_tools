defmodule MWTClient.Sandbox.Presets do
  @moduledoc """
  What the add dialog offers: the grant types, and presets that fill a
  type's form for tools whose details are known. A command grant is a
  saved command, your own script (`:saved_command`): a command an agent
  writes needs no grant.

  A preset is a JSON file (since 2026-11-17): MWT's own under
  `priv/sandbox/presets/`, yours in the identity's folder (`dir/1`). It
  fills the form's fields (`grant`), with fields of yours to fill first
  (`fill`, each `{name}` in them), and can carry what the form doesn't: a
  token grant's default request headers for its actions, the tools it
  serves, and actions. Everything it gives is copied onto the
  grant: nothing in MWT looks at which preset made it again.

  The VM-side details come from the checks of 2026-11-11: `gh` sends
  `Authorization: token`, git sends the token as the Basic password after a
  401, Hex sends the whole header value, gcloud reads a bearer token from the
  file `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` names. See `docs/agent_sandbox.md`.
  """

  @typedoc """
  A type or a preset. `fields` are the add form's params it starts from:
  `"purpose"`, `"env"`, `"file_env"`, `"hosts"`, `"git"`, `"prefix"`,
  `"source"`, `"mint"`, `"destinations"`, `"path"`.
  """
  @type t :: %{
          required(:id) => atom() | String.t(),
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
      id: :request_action,
      kind: :request,
      name: "Request action",
      icon: "hero-paper-airplane",
      blurb:
        "One request MWT sends itself with this grant's real value. Agents call it by id, and send only values.",
      guide: [
        "Write the request: the method, and the URL to a host the grant lists. What varies between calls is a parameter, $NAME, in the path or the query, or as a whole value in the JSON body.",
        "Headers are fixed. {token} stands for the real value, where the service takes it. MWT sends it itself, so the VM needs no tool and no placeholder.",
        "It has a switch of its own: enabled for a time or on startup, asking each time or auto-approved, while the grant itself stays disabled. Every call shows the exact request on its card, unless you let it through."
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
           {:ok, preset} <- preset(json) do
        {presets ++ [preset], errors}
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
  @id ~r/\A[a-z0-9][a-z0-9-]{0,40}\z/
  @fill ~r/\A[a-z][a-z0-9_]{0,30}\z/

  @doc """
  A preset from what its file holds, or what is wrong with it.

      iex> {:ok, preset} = MWTClient.Sandbox.Presets.preset(%{"id" => "acme", "kind" => "token",
      ...>   "name" => "Acme", "grant" => %{"hosts" => "api.acme.test"}})
      iex> {preset.id, preset.kind, preset.fields}
      {"acme", :token, %{"hosts" => "api.acme.test"}}
      iex> MWTClient.Sandbox.Presets.preset(%{"id" => "x", "kind" => "rocket", "name" => "X", "grant" => %{}})
      {:error, "kind is one of token, network, command"}
  """
  @spec preset(map()) :: {:ok, t()} | {:error, String.t()}
  def preset(json) do
    fill = List.wrap(json["fill"])

    cond do
      not (is_binary(json["id"]) and json["id"] =~ @id) ->
        {:error, "id is lowercase letters, digits and dashes"}

      json["id"] in Enum.map(@types, &Atom.to_string(&1.id)) ->
        {:error, "id #{json["id"]} is a type's"}

      not Map.has_key?(@kinds, json["kind"]) ->
        {:error, "kind is one of token, network, command"}

      not (is_binary(json["name"]) and String.trim(json["name"]) != "") ->
        {:error, "it needs a name"}

      not is_map(json["grant"]) ->
        {:error, "grant is an object of the add form's fields"}

      not Enum.all?(fill, &(is_map(&1) and is_binary(&1["name"]) and &1["name"] =~ @fill)) ->
        {:error, "each field to fill has a name: lowercase letters, digits and underscores"}

      Enum.any?(fill, &(&1["name"] == "token")) ->
        {:error, "{token} stands for the real value: name the field otherwise"}

      true ->
        kind = @kinds[json["kind"]]

        {:ok,
         %{
           id: json["id"],
           kind: kind,
           name: String.trim(json["name"]),
           icon: text(json["icon"]) || type(kind).icon,
           blurb: text(json["blurb"]) || "",
           guide: Enum.filter(List.wrap(json["guide"]), &is_binary/1),
           fields: Map.new(json["grant"], fn {key, value} -> {key, field(value)} end),
           fill:
             for(
               field <- fill,
               do: %{
                 name: field["name"],
                 label: text(field["label"]) || field["name"],
                 example: text(field["example"]) || ""
               }
             ),
           request_headers: text(json["request_headers"]),
           tools: Enum.filter(List.wrap(json["tools"]), &is_binary/1),
           # `subgrants` in a preset written before actions were called so.
           actions: Enum.filter(List.wrap(json["actions"] || json["subgrants"]), &is_map/1)
         }}
    end
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
