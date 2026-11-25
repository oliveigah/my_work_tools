defmodule MWTClient.Sandbox.Credential do
  @moduledoc """
  A credential: where a real value comes from, and how tools in the VM find
  its placeholder. A resource the VM reaches through MWT, as a network is;
  it decides nothing. Grants over it (`MWTClient.Sandbox.Grant`, `kind:
  :token` or a request action, `credential`) give uses of its value, where
  it may go and how each use is approved; the most permissive of those on
  counts (`MWTClient.Sandbox.Policy`).

    * `source` - `:stored`, a value you pasted, kept in the vault under the
      credential's id; or `{:minted, command}`, a command on your machine
      that prints a short-lived one, minted once for every grant over it.
    * `placeholder` - what the VM holds instead, made once. `aliases` are
      placeholders it had before (two credentials merged into one keep
      both of theirs), recognized as its own, never handed out again;
      `login_aliases`, a login file's refresh placeholders the same way.
    * `adapter` - the service it is for (`MWTClient.Sandbox.Adapter`):
      `:github`, `:google`, `:hex` or `:bearer`, any other. It decides how
      a mint's output is read (a GitHub App's key traded for a token), the
      fields its form shows (`app`, a Google login) and the grant presets
      offered over it. Chosen when it is made; one saved before it was
      chosen gets the one its preset and fields said (`upgrade/1`).
    * how values are made and kept (`mint_per`, `keep_minutes`), what
      `mwt exec` presents (`env`, `file_env`, `git`, `presents`), and what
      a preset gave (`preset`, `icon`, `request_headers`, `cli_tools`).
    * `locked` - nil, or when you locked it: a locked credential's value
      goes nowhere, whatever its grants say. A lock is yours alone: agents
      can ask for a grant, never for a lock to end.
    * `proposal` - nil, or who proposed it, when an agent did
      (`t:MWTClient.Sandbox.Grant.proposal/0`): until you accept it on its
      page, no grant over it can be accepted or turned on.

  A token grant keeps a copy of its credential's fields (`copied/0`),
  filled in by `attach/2` whenever either changes, so code that reads a
  grant's placeholder or mint reads its credential's. The copy is a view:
  you edit the credential, and every grant over it follows. A token grant
  saved before credentials existed is its own credential, under the same
  id, until `migrate/2` gives it one (`credential_id/1`).
  """

  alias MWTClient.Sandbox.Grant

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :placeholder,
    :preset,
    :icon,
    :request_headers,
    :locked,
    :proposal,
    adapter: :bearer,
    purpose: "",
    source: :stored,
    mint_per: :grant,
    keep_minutes: nil,
    presents: %{},
    env: [],
    file_env: [],
    git: false,
    cli_tools: [],
    aliases: [],
    login_aliases: [],
    app: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          purpose: String.t(),
          placeholder: String.t() | nil,
          preset: atom() | String.t() | nil,
          icon: String.t() | nil,
          request_headers: String.t() | nil,
          locked: DateTime.t() | nil,
          proposal: Grant.proposal() | nil,
          adapter: atom(),
          source: Grant.source(),
          mint_per: :grant | :host,
          keep_minutes: pos_integer() | nil,
          presents: map(),
          env: [String.t()],
          file_env: [String.t()],
          git: boolean(),
          cli_tools: [String.t()],
          aliases: [String.t()],
          login_aliases: [String.t()],
          app: %{app_id: String.t(), installation_id: String.t()} | nil
        }

  @copied [
    :placeholder,
    :source,
    :mint_per,
    :keep_minutes,
    :presents,
    :env,
    :file_env,
    :git,
    :preset,
    :icon,
    :request_headers,
    :cli_tools,
    :aliases,
    :login_aliases,
    :app,
    :adapter
  ]

  @doc "The fields a token grant copies from its credential (`attach/2`)."
  @spec copied() :: [atom()]
  def copied, do: @copied

  @doc """
  The credential a token grant made before credentials existed stands
  for: its own fields, under its id and name.

      iex> alias MWTClient.Sandbox.{Credential, Grant}
      iex> grant = %Grant{id: "github", name: "GitHub", kind: :token, placeholder: "ghp_mwt1",
      ...>   env: ["GH_TOKEN"], hosts: ["api.github.com"]}
      iex> credential = Credential.of_grant(grant)
      iex> {credential.id, credential.placeholder, credential.env}
      {"github", "ghp_mwt1", ["GH_TOKEN"]}
  """
  @spec of_grant(Grant.t()) :: t()
  def of_grant(%Grant{kind: :token} = grant) do
    fields = Map.take(Map.from_struct(grant), @copied)

    struct(
      __MODULE__,
      Map.merge(fields, %{
        id: grant.id,
        name: grant.name,
        purpose: grant.purpose || "",
        adapter: grant.adapter || MWTClient.Sandbox.Adapter.of(grant).id()
      })
    )
  end

  @doc """
  The grant with its credential's fields copied in, and its `credential`
  naming it: a token grant, or a request action. A grant of another kind
  is left as it is.
  """
  @spec attach(Grant.t(), t()) :: Grant.t()
  def attach(%Grant{kind: kind} = grant, %__MODULE__{} = credential)
      when kind in [:token, :request] do
    struct(
      grant,
      Map.put(Map.take(Map.from_struct(credential), @copied), :credential, credential.id)
    )
  end

  def attach(%Grant{} = grant, _credential), do: grant

  @doc """
  Every token grant and request action with its credential's fields
  copied in: the credential it names, or, for a token grant saved before
  credentials, its own.
  """
  @spec attach_all([Grant.t()], [t()]) :: [Grant.t()]
  def attach_all(grants, credentials) do
    by_id = Map.new(credentials, &{&1.id, &1})

    Enum.map(grants, fn
      %Grant{kind: kind} = grant when kind in [:token, :request] ->
        case by_id[Grant.credential_id(grant)] do
          %__MODULE__{} = credential -> attach(grant, credential)
          nil -> grant
        end

      grant ->
        grant
    end)
  end

  @doc """
  The credentials for `grants`, made where a token grant has none yet, and
  merged where two were made the same way: the same preset, the same mint
  command, minted the same way. Grants over one login are then one
  credential, minted once, its value kept under the id of the first; the
  others' placeholders stay its own (`aliases`), so a tool that holds one
  goes on working.

  Only minted credentials merge, and only those kept as long
  (`keep_minutes`): two stored values can't be told the same without
  reading them, and a grant kept a few minutes would have every other
  minted as often. Merged, the credential presents what each presented
  (variables, files, git) and, where their logins' ID tokens travelled in
  different headers, sends it in each grant's own carriers instead, that
  header added to them.

  Returns the grants, each naming its credential, and the credentials.
  """
  @spec migrate([Grant.t()], [t()]) :: {[Grant.t()], [t()]}
  def migrate(grants, credentials) do
    known = MapSet.new(credentials, & &1.id)

    orphans =
      for %Grant{kind: :token} = grant <- grants,
          not MapSet.member?(known, Grant.credential_id(grant)),
          do: grant

    {merged, by_grant} = merge(orphans)

    grants =
      Enum.map(grants, fn
        %Grant{kind: :token} = grant ->
          case Map.fetch(by_grant, grant.id) do
            {:ok, {credential_id, carriers}} ->
              %{grant | credential: credential_id, carriers: carriers}

            :error ->
              grant
          end

        # A request action named the credential its token grant stood for,
        # by that grant's id: it follows the grant into the merge.
        %Grant{kind: :request, credential: id} = grant when is_binary(id) ->
          case Map.fetch(by_grant, id) do
            {:ok, {credential_id, _carriers}} -> %{grant | credential: credential_id}
            :error -> grant
          end

        grant ->
          grant
      end)

    credentials = credentials ++ merged
    {attach_all(grants, credentials), credentials}
  end

  # Groups token grants by how their value is made: each group one
  # credential, under its first grant's id. Returns the credentials and,
  # by grant id, the credential each grant is over and its carriers.
  defp merge(grants) do
    grants
    |> Enum.group_by(&making/1)
    |> Enum.sort_by(fn {_making, [first | _]} ->
      Enum.find_index(grants, &(&1.id == first.id))
    end)
    |> Enum.reduce({[], %{}}, fn
      {nil, group}, acc ->
        Enum.reduce(group, acc, &one(&1, &2))

      # Grants that already name a credential MWT has no record of: one
      # credential under that id, theirs.
      {{:named, id}, [first | _] = group}, {credentials, by_grant} ->
        credential = %{
          of_grant(first)
          | id: id,
            aliases:
              group
              |> Enum.map(& &1.placeholder)
              |> Enum.reject(&(is_nil(&1) or &1 == first.placeholder))
              |> Enum.uniq()
        }

        {credentials ++ [credential],
         Map.merge(by_grant, Map.new(group, &{&1.id, {id, &1.carriers}}))}

      {_making, [_single] = group}, acc ->
        Enum.reduce(group, acc, &one(&1, &2))

      {_making, [first | rest] = group}, {credentials, by_grant} ->
        headers = group |> Enum.map(&login_header/1) |> Enum.uniq()
        same_header? = match?([_], headers)

        credential = %{
          of_grant(first)
          | env: group |> Enum.flat_map(& &1.env) |> Enum.uniq(),
            file_env: group |> Enum.flat_map(& &1.file_env) |> Enum.uniq(),
            git: Enum.any?(group, & &1.git),
            presents: merged_presents(group, same_header?),
            aliases: Enum.map(rest, & &1.placeholder) |> Enum.reject(&is_nil/1),
            name: credential_name(group)
        }

        # The login file the merged credential presents is one of theirs:
        # the others' refresh placeholders stay its own too.
        own_login = get_in(credential.presents, [:login, :refresh])

        credential = %{
          credential
          | login_aliases:
              group
              |> Enum.map(&Grant.login_placeholder/1)
              |> Enum.reject(&(is_nil(&1) or &1 == own_login))
        }

        carriers =
          Map.new(group, fn grant ->
            header = login_header(grant)

            carriers =
              if same_header? or header in [nil, ""],
                do: grant.carriers,
                else: Enum.uniq(Grant.carriers(grant) ++ [header])

            {grant.id, {credential.id, carriers}}
          end)

        {credentials ++ [credential], Map.merge(by_grant, carriers)}
    end)
  end

  defp one(grant, {credentials, by_grant}),
    do:
      {credentials ++ [of_grant(grant)], Map.put(by_grant, grant.id, {grant.id, grant.carriers})}

  # How a grant's value is made, for merging: only minted ones, by preset,
  # command and per-host minting; nil keeps it a credential of its own.
  defp making(%Grant{credential: id}) when is_binary(id), do: {:named, id}

  # How long a value is kept is part of how it is made: a grant kept a few
  # minutes, for a service that takes only young tokens, stays apart, so
  # the others aren't minted that often too.
  defp making(%Grant{source: {:minted, command}} = grant),
    do: {grant.preset, String.trim(command), grant.mint_per, grant.keep_minutes}

  defp making(%Grant{}), do: nil

  defp login_header(%Grant{presents: %{login: %{header: header}}}), do: header
  defp login_header(%Grant{}), do: nil

  # What the merged grants presented, together: one metadata server (the
  # first's settings) and one login, whose ID token goes in the header they
  # shared, or in each grant's carriers when they differed.
  defp merged_presents(group, same_header?) do
    metadata = Enum.find_value(group, &get_in(&1.presents, [:metadata]))
    login = Enum.find_value(group, &get_in(&1.presents, [:login]))

    %{}
    |> then(&if(metadata, do: Map.put(&1, :metadata, metadata), else: &1))
    |> then(fn presents ->
      cond do
        is_nil(login) -> presents
        same_header? -> Map.put(presents, :login, login)
        true -> Map.put(presents, :login, %{login | header: ""})
      end
    end)
  end

  # A merged credential is named for what its grants share: their preset's
  # name when they came from one of MWT's, else the first grant's.
  defp credential_name([first | _] = group) do
    with [preset] when not is_nil(preset) <- Enum.uniq(Enum.map(group, & &1.preset)),
         {:ok, %{name: name}} <- MWTClient.Sandbox.Presets.find(to_string(preset)) do
      name
    else
      _ -> first.name
    end
  end

  @doc "Whether you locked the credential: its value then goes nowhere."
  @spec locked?(t()) :: boolean()
  def locked?(%__MODULE__{locked: nil}), do: false
  def locked?(%__MODULE__{}), do: true

  @doc """
  Every placeholder the credential answers to: its own, and those it had
  before a merge.
  """
  @spec placeholders(t() | Grant.t()) :: [String.t()]
  def placeholders(%{placeholder: placeholder, aliases: aliases}),
    do: Enum.reject([placeholder | aliases || []], &is_nil/1)

  @doc """
  A credential saved by an older MWT, brought up to date: one saved before
  it named its adapter gets the one its preset and fields said
  (`MWTClient.Sandbox.Adapter.of/1`).

      iex> alias MWTClient.Sandbox.Credential
      iex> Credential.upgrade(%{id: "gh", name: "GitHub", preset: "github"}).adapter
      :github
      iex> Credential.upgrade(%{id: "k", name: "Key", adapter: :hex}).adapter
      :hex
  """
  @spec upgrade(map()) :: t()
  def upgrade(%{} = saved) do
    fields = Map.delete(saved, :__struct__)
    credential = struct(__MODULE__, Map.put(fields, :adapter, nil))

    adapter =
      if is_atom(fields[:adapter]) and not is_nil(fields[:adapter]),
        do: fields[:adapter],
        else: MWTClient.Sandbox.Adapter.of(credential).id()

    %{credential | adapter: adapter}
  end
end
