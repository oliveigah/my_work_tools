defmodule MWTClient.Sandbox.Resource do
  @moduledoc """
  What the VM can be given uses of through MWT, each a resource you can
  lock: the credentials (`MWTClient.Sandbox.Credential`), the networks
  (`MWTClient.Sandbox.Network`, the Internet included), your machine,
  where saved commands run and the projects' git, shared folders and
  workspace reach, and MWT's tools (notes, diagrams, flash cards, HTTP
  samples). Pure.

  Each grant mediates one of them (`MWTClient.Sandbox.Grant.resource/1`);
  a use may go through several, each needing a grant of its own
  (`MWTClient.Sandbox.Policy`). A resource decides nothing about who may
  use it: it holds what it is, and the user's limits on it, a lock and,
  for a network, the hosts it blocks.
  """

  alias MWTClient.Sandbox.{Credential, Grant, Network}

  @type id :: {:credential, String.t()} | {:network, String.t()} | :machine | :mwt

  @doc "Every resource there is: each credential, each network, your machine, MWT's tools."
  @spec all([Credential.t()], [Network.t()]) :: [id()]
  def all(credentials, networks) do
    for(c <- credentials, do: {:credential, c.id}) ++
      for(n <- networks, do: {:network, n.id}) ++ [:machine, :mwt]
  end

  @doc "A resource's name, as its page shows it."
  @spec name(id(), [Credential.t()], [Network.t()]) :: String.t()
  def name({:credential, id}, credentials, _networks),
    do: Enum.find_value(credentials, id, &(&1.id == id && &1.name))

  def name({:network, id}, _credentials, networks),
    do: Enum.find_value(networks, id, &(&1.id == id && &1.name))

  def name(:machine, _credentials, _networks), do: "Host commands"
  def name(:mwt, _credentials, _networks), do: "MWT's tools"

  @doc "What kind of resource it is, in a word."
  @spec kind_words(id()) :: String.t()
  def kind_words({:credential, _id}), do: "Credential"
  def kind_words({:network, _id}), do: "Network"
  def kind_words(:machine), do: "Host commands"
  def kind_words(:mwt), do: "MWT's tools"

  @doc "The resource's path on MWT's pages."
  @spec path(id()) :: String.t()
  def path({:credential, id}), do: "/tools/sandbox/resources/credential/#{id}"
  def path({:network, id}), do: "/tools/sandbox/resources/network/#{id}"
  def path(:machine), do: "/tools/sandbox/resources/machine"
  def path(:mwt), do: "/tools/sandbox/resources/mwt"

  @doc "The resource a path names (`path/1`), or nil."
  @spec from_path(String.t(), String.t() | nil) :: id() | nil
  def from_path("credential", id) when is_binary(id), do: {:credential, id}
  def from_path("network", id) when is_binary(id), do: {:network, id}
  def from_path("machine", _id), do: :machine
  def from_path("mwt", _id), do: :mwt
  def from_path(_kind, _id), do: nil

  @doc """
  Whether `resource` is one an agent proposed that you haven't accepted
  yet: nothing over it can be accepted or turned on until you do.
  """
  @spec to_review?(id(), [Credential.t()], [Network.t()]) :: boolean()
  def to_review?({:credential, id}, credentials, _networks),
    do: match?(%{proposal: %{reviewed_at: nil}}, Enum.find(credentials, &(&1.id == id)))

  def to_review?({:network, id}, _credentials, networks),
    do: match?(%{proposal: %{reviewed_at: nil}}, Enum.find(networks, &(&1.id == id)))

  def to_review?(_built_in, _credentials, _networks), do: false

  @doc "The grants over `resource` among `grants`."
  @spec grants([Grant.t()], id()) :: [Grant.t()]
  def grants(grants, resource), do: Enum.filter(grants, &(Grant.resource(&1) == resource))

  @doc """
  What a refused use says of a locked resource: locked by the user, and
  nothing an agent can ask for changes it.
  """
  @spec locked_words(id()) :: String.t()
  def locked_words({:credential, id}),
    do: "The credential #{id} is locked by the user: its value goes nowhere until they unlock it."

  def locked_words({:network, id}),
    do: "The network #{id} is locked by the user: nothing reaches it until they unlock it."

  def locked_words(:machine),
    do:
      "Host commands are locked by the user: nothing an agent asks runs on their machine, a command it writes or a saved one, until they unlock them."

  def locked_words(:mwt),
    do:
      "MWT's tools are locked by the user: no note, diagram or card is read or written, and no git fetch, handoff, sync or workspace copy happens, until they unlock them."
end
