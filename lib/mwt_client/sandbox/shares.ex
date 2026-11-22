defmodule MWTClient.Sandbox.Shares do
  @moduledoc """
  Decides whether a host folder may be shared with the VM.

  Five rules:

    * **No credential folders.** Sharing `~/.ssh`, `~/.optmem`, MWT's own data
      folder and the like, or any folder holding one of them, hands the VM
      what it must never hold.
    * **No overlaps.** Two copies would write the same paths in the VM.
      (When shares were mounted, root in the VM could unmount a read-only
      folder inside a read-write one and write to the host folder under it;
      the checks of 2026-11-11 did exactly that.)
    * **Real folders only.** The path is resolved through every symlink
      before it is judged, so a link inside a project cannot smuggle in a
      folder the rules refuse.
    * **Not inside a git working tree,** nor where the VM keeps its own
      disks. A folder inside a repository would be copied with what that
      repository ignores; share the repository, which is a project. And a
      copy at `/work`, `/cache`, `/root` or `/mnt` would land on the VM's
      own.
    * **Not the workspace,** nor a folder holding it or inside it: MWT
      shares its own half of it already (`MWTClient.Sandbox.Workspace`),
      and the VM's half comes the other way.

  Pure apart from reading the filesystem to resolve the path.
  """

  alias MWTClient.Sandbox.Share

  @max_links 40

  # Relative to the home folder: what holds credentials, keys or the
  # memory of host agents.
  @refused_in_home [
    {".ssh", "SSH keys"},
    {".gnupg", "GPG keys"},
    {".optmem", "your host agents' memory"},
    {".microsandbox", "microsandbox's own state"},
    {".aws", "AWS credentials"},
    {".kube", "Kubernetes credentials"},
    {".docker", "Docker credentials"},
    {".config/gcloud", "Google Cloud credentials"},
    {".config/gh", "the GitHub CLI's login"},
    {".hex", "your Hex login"},
    {".local/share/keyrings", "the desktop keyring"},
    {".password-store", "your password store"}
  ]

  @type reason ::
          :blank
          | :not_absolute
          | :missing
          | :not_a_folder
          | :loop
          | :home
          | :root
          | {:refused, String.t(), String.t()}
          | {:overlaps, String.t()}
          | :duplicate
          | {:inside_repository, String.t()}
          | {:vm_path, String.t()}
          | {:workspace, String.t()}

  @doc """
  Checks `path` against the folders already shared.

  ## Options

    * `:home` - the home folder, defaults to the user's
    * `:data_dir` - MWT's data folder, defaults to `MWTClient.Accounts.root/0`
    * `:workspace` - the identity's workspace, or nil

  Returns the resolved share, or why it is refused.
  """
  @spec validate(String.t(), [Share.t()], keyword()) :: {:ok, Share.t()} | {:error, reason()}
  def validate(path, shares, opts \\ []) do
    home = opts |> Keyword.get_lazy(:home, &System.user_home!/0) |> realpath_or_self()

    data_dir =
      opts |> Keyword.get_lazy(:data_dir, &MWTClient.Accounts.root/0) |> realpath_or_self()

    with {:ok, path} <- normalize(path, home),
         {:ok, real} <- realpath(path),
         :ok <- folder(real),
         :ok <- not_root_or_home(real, home),
         :ok <- not_refused(real, home, data_dir),
         :ok <- not_vm_path(real),
         :ok <- not_inside_repository(real),
         :ok <- not_workspace(real, Keyword.get(opts, :workspace)),
         :ok <- no_overlap(real, shares) do
      {:ok, %Share{path: real}}
    end
  end

  # Where the VM keeps its own disks and MWT's folder: a copy there would
  # land on them.
  @vm_paths ~w(/work /cache /root /mnt)

  defp not_vm_path(path) do
    case Enum.find(@vm_paths, &(within?(path, &1) or within?(&1, path))) do
      nil -> :ok
      taken -> {:error, {:vm_path, taken}}
    end
  end

  # A repository itself is fine: it is a project, and nothing of it is
  # copied. A folder inside one is not.
  defp not_inside_repository(path) do
    case MWTClient.Sandbox.FolderSync.enclosing(Path.dirname(path)) do
      nil -> :ok
      root -> if path == "/", do: :ok, else: {:error, {:inside_repository, root}}
    end
  end

  defp not_workspace(_path, nil), do: :ok

  defp not_workspace(path, workspace) do
    if within?(path, workspace) or within?(workspace, path),
      do: {:error, {:workspace, workspace}},
      else: :ok
  end

  @doc "A sentence explaining a refusal, for the settings page."
  @spec explain(reason()) :: String.t()
  def explain(:blank), do: "Enter a folder to share."
  def explain(:not_absolute), do: "Use a full path, starting with / or ~."
  def explain(:missing), do: "That folder does not exist."
  def explain(:not_a_folder), do: "That is a file, not a folder."
  def explain(:loop), do: "That path loops through symlinks."
  def explain(:root), do: "The whole filesystem cannot be shared."

  def explain(:home),
    do: "Your home folder holds your credentials. Share the project folders inside it instead."

  def explain({:refused, folder, what}),
    do: "This would share #{folder}, which holds #{what}."

  def explain({:overlaps, other}),
    do:
      "Overlaps #{other}, which is already shared: both would be copied to the same place in the VM, so pick one or the other."

  def explain(:duplicate), do: "That folder is already shared."

  def explain({:inside_repository, root}),
    do:
      "That folder is inside the git repository #{root}: its copy would carry what the repository ignores. Share the repository instead; it reaches the VM as a project."

  def explain({:vm_path, taken}),
    do: "The VM keeps its own files at #{taken}: a copy there would land on them."

  def explain({:workspace, workspace}),
    do:
      "#{workspace} is the workspace, which MWT shares with the VM itself: put files for the VM in its to-vm folder instead."

  defp normalize(path, home) do
    case String.trim(path) do
      "" -> {:error, :blank}
      "~" -> {:ok, home}
      "~/" <> rest -> {:ok, Path.join(home, rest) |> Path.expand()}
      "/" <> _ = absolute -> {:ok, Path.expand(absolute)}
      _relative -> {:error, :not_absolute}
    end
  end

  defp folder(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :not_a_folder}
      {:error, _} -> {:error, :missing}
    end
  end

  defp not_root_or_home("/", _home), do: {:error, :root}
  defp not_root_or_home(home, home), do: {:error, :home}
  defp not_root_or_home(_path, _home), do: :ok

  defp not_refused(path, home, data_dir) do
    case refused(path, home: home, data_dir: data_dir) do
      nil -> :ok
      {folder, what} -> {:error, {:refused, folder, what}}
    end
  end

  @doc """
  The folder holding what the VM must never reach (credentials, keys, MWT's
  own data) that `path` is in or holds, with what it holds; nil when there
  is none. `path` is real (no symlinks). Options as for `validate/4`.
  """
  @spec refused(String.t(), keyword()) :: {String.t(), String.t()} | nil
  def refused(path, opts \\ []) do
    home = opts |> Keyword.get_lazy(:home, &System.user_home!/0) |> realpath_or_self()

    data_dir =
      opts |> Keyword.get_lazy(:data_dir, &MWTClient.Accounts.root/0) |> realpath_or_self()

    [
      {data_dir, "MWT's own data"}
      | Enum.map(@refused_in_home, fn {rel, what} -> {Path.join(home, rel), what} end)
    ]
    |> Enum.find(fn {folder, _what} -> within?(path, folder) or within?(folder, path) end)
  end

  defp no_overlap(path, shares) do
    Enum.find_value(shares, :ok, fn %Share{path: other} ->
      cond do
        other == path -> {:error, :duplicate}
        within?(path, other) or within?(other, path) -> {:error, {:overlaps, other}}
        true -> nil
      end
    end)
  end

  @doc "Whether `path` is `folder` or somewhere inside it. Both are plain absolute paths."
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(path, folder), do: path == folder or String.starts_with?(path, folder <> "/")

  defp realpath_or_self(path) do
    case realpath(Path.expand(path)) do
      {:ok, real} -> real
      {:error, _} -> Path.expand(path)
    end
  end

  @doc """
  `path` with every symlink along it resolved, as the kernel would resolve
  it. A missing part ends the walk where it is: the rest is joined as given.
  """
  @spec realpath(String.t()) :: {:ok, String.t()} | {:error, :loop}
  def realpath(path), do: resolve(Path.split(path), "/", 0)

  defp resolve(_parts, _at, links) when links > @max_links, do: {:error, :loop}
  defp resolve([], at, _links), do: {:ok, at}
  defp resolve(["/" | rest], _at, links), do: resolve(rest, "/", links)
  defp resolve(["." | rest], at, links), do: resolve(rest, at, links)
  defp resolve([".." | rest], at, links), do: resolve(rest, Path.dirname(at), links)

  defp resolve([part | rest], at, links) do
    next = Path.join(at, part)

    case File.read_link(next) do
      {:ok, target} ->
        target_parts = Path.split(target)
        start = if Path.type(target) == :absolute, do: "/", else: at
        resolve(target_parts ++ rest, start, links + 1)

      {:error, _not_a_link} ->
        resolve(rest, next, links)
    end
  end
end
