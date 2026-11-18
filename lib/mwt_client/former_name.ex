defmodule MWTClient.FormerName do
  @moduledoc """
  MWT was MDT. What an MDT install left on this machine, and in its VM,
  carries MDT's names; this module is the one place that knows them.

  - **An install MDT made stays where it is.** Its data folder,
    `~/.mdt_client`, is MWT's while there is no `~/.mwt_client`
    (`data_dir/2`), and the VMs in it keep the names microsandbox recorded
    them by (`name/0`): their msb name (`mdt-…`), msb's home
    (`$XDG_RUNTIME_DIR/mdt/…`) and the root of their bubble (`/mdt`).
    microsandbox writes absolute paths into a VM's records (its root
    disk's journal, its image cache), so moving any of them would leave
    the VM unable to start. A new install is `~/.mwt_client`, with MWT's
    names.
  - **Saved terms** name MDT's modules (`MDTClient.Sandbox.Grant`, …) and
    its own grant kind (`:mdt`): they are read as MWT's (`term/1`),
    wherever MWT decodes what it saved (`MWTClient.Vault.open/2`,
    `MWTClient.Storage.Values.from_term/1`, an export).
  - **The grants of MDT's tools** had ids of its name (`grant_id/1`).

  What keeps MDT's name in every install, because data already written
  depends on it, is marked where it is: the vault's and the export's
  sealed constants (`mdt:vault:verifier:v1`, `mdt:export:verifier:v1`)
  and an export's first bytes (`MDTEXPORT`).
  """

  @doc "Where MDT kept its data: `~/.mdt_client`."
  def data_dir, do: Path.join(System.user_home!(), ".mdt_client")

  @doc """
  The data folder to use, of MDT's `former` and MWT's `current`: MDT's
  while it is there and MWT's isn't.
  """
  @spec data_dir(Path.t(), Path.t()) :: Path.t()
  def data_dir(former, current) do
    if File.dir?(former) and not File.exists?(current), do: former, else: current
  end

  @doc """
  The name this install's VMs are recorded by in microsandbox, and their
  bubbles' root: `"mdt"` in the data folder MDT made, `"mwt"` elsewhere.
  """
  @spec name() :: String.t()
  def name, do: if(MWTClient.Accounts.root() == data_dir(), do: "mdt", else: "mwt")

  @doc """
  A term MDT saved, with its module names (`Elixir.MDTClient…`) and its
  grant kind (`:mdt`) read as MWT's. Anything else is left as it is.

      iex> MWTClient.FormerName.term(%{__struct__: :"Elixir.MDTClient.Sandbox.Snapshot", kind: :mdt})
      %{__struct__: MWTClient.Sandbox.Snapshot, kind: :mwt}

      iex> MWTClient.FormerName.term({[:ok, "mdt" | :tail], %{"MDTClient" => :mdt_x}})
      {[:ok, "mdt" | :tail], %{"MDTClient" => :mdt_x}}
  """
  @spec term(term()) :: term()
  def term(term) when is_atom(term), do: atom(term)
  def term([head | tail]), do: [term(head) | term(tail)]

  def term(map) when is_map(map),
    do: map |> :maps.to_list() |> Map.new(fn {key, value} -> {term(key), term(value)} end)

  def term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&term/1) |> List.to_tuple()

  def term(other), do: other

  @doc """
  `binary_to_term/1` of `binary`, then `term/1` when it names anything of
  MDT's: what MWT wrote itself is decoded and nothing more.
  """
  @spec binary_to_term(binary()) :: term()
  def binary_to_term(binary) do
    decoded = :erlang.binary_to_term(binary)

    # External term format: a module's name is its atom's text, and `:mdt`
    # a small UTF-8 atom of three bytes.
    if :binary.match(binary, ["Elixir.MDTClient", <<119, 3, "mdt">>]) == :nomatch,
      do: decoded,
      else: term(decoded)
  end

  defp atom(:mdt), do: :mwt

  defp atom(atom) do
    case Atom.to_string(atom) do
      # Only from what MWT sealed or an export authenticated: as many atoms
      # as the term had already.
      "Elixir.MDTClient" <> rest -> String.to_atom("Elixir.MWTClient" <> rest)
      _ -> atom
    end
  end

  @doc """
  The id a grant of MWT's tools has, for one MDT gave it.

      iex> MWTClient.FormerName.grant_id("mdt-read")
      "mwt-read"

      iex> MWTClient.FormerName.grant_id("mdt-notes")
      "mdt-notes"
  """
  @spec grant_id(String.t()) :: String.t()
  def grant_id("mdt-" <> tools) when tools in ["read", "create", "change"], do: "mwt-" <> tools
  def grant_id(id), do: id
end
