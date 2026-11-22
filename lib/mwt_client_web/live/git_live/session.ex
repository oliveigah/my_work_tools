defmodule MWTClientWeb.GitLive.Session do
  @moduledoc """
  What the Git tool keeps for an identity across restarts: the
  repositories it had open, in tab order, with the one in front, and the
  SSH key pair it uses for remotes.

  Each is a document of the identity's own (`MWTClient.Storage.Documents`),
  in its encrypted library, apart so that saving one never writes over
  the other: another identity on this machine keeps its own. Only paths
  are kept, of worktrees and of key files; a worktree that has since moved
  is dropped the first time it fails to open.

  Both were once app-wide, in `MWTClient.Preferences`. The first identity
  to read one here takes what the preferences still hold of it, which
  then leaves them: one identity's tabs and key never show to another.
  """

  alias MWTClient.Preferences
  alias MWTClient.Storage.Documents

  @tabs "git.tabs"
  @ssh_key "git.ssh_key"

  # Where `MWTClient.Preferences` kept them for every identity at once.
  @legacy_tabs ~w(git_repositories git_active_repository)
  @legacy_ssh_key ~w(git_ssh_private_key git_ssh_public_key)

  @type tabs :: %{paths: [Path.t()], active: Path.t() | nil}
  @type ssh_key :: %{private_key: Path.t(), public_key: Path.t()}

  @doc "The worktree paths that were open, in tab order, and the one in front."
  @spec tabs(String.t()) :: tabs()
  def tabs(username) do
    case Documents.get(username, @tabs) do
      {:ok, tabs} -> tabs
      :none -> adopt(username, @tabs, @legacy_tabs, &legacy_tabs/1) || %{paths: [], active: nil}
    end
  end

  @doc "Keeps the open paths and which of them is in front."
  @spec remember(String.t(), [Path.t()], Path.t() | nil) :: :ok
  def remember(username, paths, active) when is_list(paths) do
    :ok = Documents.put(username, @tabs, %{paths: Enum.uniq(paths), active: active})
  end

  @doc "Drops one path from the open ones, leaving the rest alone."
  @spec forget(String.t(), Path.t()) :: :ok
  def forget(username, path) do
    %{paths: paths, active: active} = tabs(username)
    remember(username, Enum.reject(paths, &(&1 == path)), if(active != path, do: active))
  end

  @doc "The SSH key pair the Git tool uses for remotes, or nil: git's own way."
  @spec ssh_key(String.t()) :: ssh_key() | nil
  def ssh_key(username) do
    case Documents.get(username, @ssh_key) do
      {:ok, key} -> key
      :none -> adopt(username, @ssh_key, @legacy_ssh_key, &legacy_ssh_key/1)
    end
  end

  @doc "Keeps the SSH key pair the Git tool uses for remotes from now on."
  @spec keep_ssh_key(String.t(), Path.t(), Path.t()) :: :ok
  def keep_ssh_key(username, private_key, public_key)
      when is_binary(private_key) and is_binary(public_key) do
    :ok = Documents.put(username, @ssh_key, %{private_key: private_key, public_key: public_key})
  end

  @doc "Goes back to git's own way of reaching remotes."
  @spec forget_ssh_key(String.t()) :: :ok
  def forget_ssh_key(username), do: :ok = Documents.put(username, @ssh_key, nil)

  # What the preferences still hold for every identity, taken by the first
  # that asks, as its own; nil when they hold none.
  defp adopt(username, name, keys, read) do
    preferences = Preferences.all()

    case read.(preferences) do
      nil ->
        nil

      value ->
        :ok = Documents.put(username, name, value)
        Enum.each(keys, &Preferences.delete/1)
        value
    end
  end

  defp legacy_tabs(%{"git_repositories" => [_ | _] = paths} = preferences) do
    active = preferences["git_active_repository"]
    %{paths: Enum.filter(paths, &is_binary/1), active: if(is_binary(active), do: active)}
  end

  defp legacy_tabs(_preferences), do: nil

  defp legacy_ssh_key(%{"git_ssh_private_key" => private, "git_ssh_public_key" => public})
       when is_binary(private) and private != "" and is_binary(public) and public != "",
       do: %{private_key: private, public_key: public}

  defp legacy_ssh_key(_preferences), do: nil
end
