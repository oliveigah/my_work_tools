defmodule MWTClient.Sandbox.Workspace do
  @moduledoc """
  The workspace: a folder of yours that MWT makes for the identity's VM,
  an inbox and outbox for files that aren't a project's code. An agent
  leaves a file a program of yours reads; a script of yours leaves its
  result for the agent to fetch. It moves files, nothing more: whoever put
  a file there removes it once it served, and MWT keeps nothing there for
  any time.

  On this machine, `~/mwt-vm` (`ensure/1`), at the same path in the VM,
  and named on both sides by `MWT_WORKSPACE` (`variable/0`). Two halves,
  each written by one side only, so a file never changes on both and
  there is nothing to reconcile:

    * `to-vm/` (`to_vm/1`): yours. What your commands and scripts leave
      for the agent. It reaches the VM as a shared folder does, read-only
      there (`MWTClient.Sandbox.FolderSync`,
      `MWTClient.Sandbox.ShareMounts`), synced when shared folders are.
    * `from-vm/` (`from_vm/1`): the VM's. Its own folder on its Work disk
      (`vm_store/0`), writable there, copied here
      (`MWTClient.Sandbox.CopyBack`) under the grant *Workspace: write to
      your machine*, read-only here.

  Beside them, MWT's own: `.mwt-workspace` (`marker/1`), which holds the
  identity's id, since MWT uses only a folder it made; `.trackerignore`,
  which keeps GNOME's indexer out; and `.mwt-incoming` (`stage/1`), where
  a copy back stages files before they move into `from-vm/`.

  In the VM, `~/mwt-vm` itself is read-only (`arrange/2`), so a file left
  anywhere else in it fails at once instead of never travelling.

  A second identity on this machine gets `~/mwt-vm-<name>`. A folder at
  that path MWT didn't make (no marker, or a symlink) is never taken over:
  the workspace waits, and the Overview says to move it away.
  """

  alias MWTClient.Accounts
  alias MWTClient.Sandbox.{Guest, Shares}

  @name "mwt-vm"
  @marker ".mwt-workspace"
  @stage ".mwt-incoming"
  @variable "MWT_WORKSPACE"
  # The VM's side: the folder it writes, and the frame shown read-only at
  # the workspace's path, holding where each half is shown.
  @vm_base "/work/.workspace"
  @vm_store "/work/.workspace/from-vm"
  @vm_frame "/work/.workspace/frame"

  @typedoc "Why there is no workspace: a folder of someone else's in its place, or a failure."
  @type reason :: {:foreign, Path.t()} | {:failed, Path.t(), String.t()}

  @doc "The variable naming the workspace, in the VM and in commands here."
  @spec variable() :: String.t()
  def variable, do: @variable

  @doc "Your half: what your machine writes and the VM reads."
  @spec to_vm(Path.t()) :: Path.t()
  def to_vm(root), do: Path.join(root, "to-vm")

  @doc "The VM's half: what the VM writes and your machine reads."
  @spec from_vm(Path.t()) :: Path.t()
  def from_vm(root), do: Path.join(root, "from-vm")

  @doc "Where a copy back stages files on this machine, beside the halves."
  @spec stage(Path.t()) :: Path.t()
  def stage(root), do: Path.join(root, @stage)

  @doc "The file that says the folder is MWT's, for this identity."
  @spec marker(Path.t()) :: Path.t()
  def marker(root), do: Path.join(root, @marker)

  @doc "Where the VM keeps its half, on its Work disk."
  @spec vm_store() :: Path.t()
  def vm_store, do: @vm_store

  @doc """
  Whether `path` is the workspace at `root` or inside it.

      iex> MWTClient.Sandbox.Workspace.within?("/home/me/mwt-vm/to-vm/a", "/home/me/mwt-vm")
      true
      iex> MWTClient.Sandbox.Workspace.within?("/home/me/mwt-vm-2", "/home/me/mwt-vm")
      false
  """
  @spec within?(Path.t(), Path.t() | nil) :: boolean()
  def within?(_path, nil), do: false
  def within?(path, root), do: Shares.within?(path, root)

  @doc """
  The home folder the workspace goes in: yours, or what tests put in its
  place for an identity (`config/test.exs`).
  """
  @spec home(String.t()) :: Path.t()
  def home(username) do
    case Application.get_env(:mwt_client, __MODULE__, [])[:home] do
      nil -> System.user_home!()
      home -> home.(username)
    end
  end

  @doc """
  The paths the identity's workspace may have, first to last: `~/mwt-vm`,
  and `~/mwt-vm-<name>` when another identity holds the first.

      iex> MWTClient.Sandbox.Workspace.candidates("/home/me", "Work Laptop")
      ["/home/me/mwt-vm", "/home/me/mwt-vm-work-laptop"]
  """
  @spec candidates(Path.t(), String.t()) :: [Path.t()]
  def candidates(home, username) do
    slug =
      username
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> then(&if(&1 == "", do: "identity", else: &1))

    [Path.join(home, @name), Path.join(home, "#{@name}-#{slug}")]
  end

  @doc """
  The identity's workspace, made when it isn't there yet, with both halves
  and MWT's files, its modes set: `{:ok, root}`, or why there is none.
  """
  @spec ensure(String.t()) :: {:ok, Path.t()} | {:error, reason()}
  def ensure(username) do
    id = Accounts.id(username)
    find(candidates(home(username), username), id, &make(&1, id))
  end

  @doc """
  The identity's workspace as it is, made by nothing: `{:ok, root}` when
  MWT made it already, `:none` when it isn't there yet, or why there is
  none.
  """
  @spec locate(String.t()) :: {:ok, Path.t()} | :none | {:error, reason()}
  def locate(username) do
    id = Accounts.id(username)
    find(candidates(home(username), username), id, fn _root -> :none end)
  end

  # The first path that is ours, or the first free one handed to `free`. A
  # folder of another identity's sends us to the next path; one MWT didn't
  # make stops there.
  defp find([], _id, _free), do: :none

  defp find([root | rest], id, free) do
    case owner(root) do
      :none -> free.(root)
      {:identity, ^id} -> ready(root)
      {:identity, _other} -> find(rest, id, free)
      :foreign -> {:error, {:foreign, root}}
    end
  end

  defp owner(root) do
    case File.lstat(root) do
      {:error, :enoent} ->
        :none

      {:ok, %File.Stat{type: :directory}} ->
        case File.lstat(marker(root)) do
          {:ok, %File.Stat{type: :regular}} ->
            case File.read(marker(root)) do
              {:ok, text} -> {:identity, String.trim(text)}
              {:error, _} -> :foreign
            end

          _no_marker ->
            :foreign
        end

      _a_file_or_link ->
        :foreign
    end
  end

  defp make(root, id) do
    with :ok <- File.mkdir(root),
         :ok <- File.write(marker(root), id <> "\n") do
      ready(root)
    else
      {:error, reason} -> {:error, {:failed, root, :file.format_error(reason) |> to_string()}}
    end
  end

  # Both halves there, real folders; what GNOME's indexer skips; the VM's
  # half read-only.
  defp ready(root) do
    with :ok <- folder(to_vm(root), nil),
         :ok <- folder(from_vm(root), 0o555),
         :ok <- tracker_ignore(root) do
      {:ok, root}
    else
      {:error, reason} -> {:error, {:failed, root, reason}}
    end
  end

  # A half is a folder: a link or a file in its place is MWT's to replace,
  # since nothing but MWT writes there.
  defp folder(path, mode) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _other} ->
        File.rm(path)
        File.mkdir(path)

      {:error, :enoent} ->
        File.mkdir(path)

      {:error, reason} ->
        {:error, reason}
    end
    |> case do
      :ok when is_integer(mode) -> File.chmod(path, mode)
      :ok -> :ok
      {:error, reason} -> {:error, "#{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp tracker_ignore(root) do
    path = Path.join(root, ".trackerignore")

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _missing -> File.write(path, "")
    end
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, ".trackerignore: #{:file.format_error(reason)}"}
    end
  end

  # Runs as root in the VM. Arguments: how to show (mount, or link in a
  # test's stand-in), the workspace's path, the VM's half and the frame.
  # The frame, read-only at the workspace's path, holds an empty folder
  # for each half; the VM's half is bound writable over its own. Your half
  # is a shared folder's copy, which `MWTClient.Sandbox.ShareMounts` shows
  # over the other, after this. Busybox's mount does all of it.
  @arrange ~S"""
  set -u
  mode=$1 root=$2 store=$3 frame=$4
  mkdir -p -- "$store" "$frame/to-vm" "$frame/from-vm" || exit 1
  case $mode in
    mount)
      if ! mountpoint -q "$root" 2>/dev/null; then
        if ! { mkdir -p -- "$root" && mount --bind "$frame" "$root"; }; then
          echo "$root couldn't be shown in the VM." >&2
          exit 1
        elif ! mount -o remount,bind,ro "$root"; then
          umount "$root" 2>/dev/null
          echo "$root couldn't be made read-only, so it isn't shown." >&2
          exit 1
        fi
      fi
      if ! mountpoint -q "$root/from-vm" 2>/dev/null; then
        if ! mount --bind "$store" "$root/from-vm"; then
          echo "$root/from-vm couldn't be shown in the VM." >&2
          exit 1
        fi
      fi
      ;;
    link)
      mkdir -p -- "$root" || exit 1
      [ -L "$root/from-vm" ] || ln -s -- "$store" "$root/from-vm" || exit 1
      ;;
  esac
  """

  @doc """
  Shows the workspace at `root` in the VM behind `guest`: read-only, with
  the VM's own half writable in it. Cheap when it is shown already.
  """
  @spec arrange(Guest.t(), Path.t()) :: :ok | {:error, String.t()}
  def arrange(guest, root) do
    mode = Map.get(guest, :show, :mount) |> Atom.to_string()

    words =
      ["sh", "-c", @arrange, "mwt-workspace", mode, guest.place.(root)] ++
        Enum.map([@vm_store, @vm_frame], guest.place)

    case guest.exec.(words) do
      {:ok, _output} -> :ok
      {:error, text} -> {:error, "The workspace couldn't be shown in the VM: " <> text}
    end
  end

  @doc """
  Opens the workspace in your file manager (`xdg-open`), or what tests
  put in its place (`config/test.exs`).
  """
  @spec open(Path.t()) :: :ok | {:error, String.t()}
  def open(root) do
    case Application.get_env(:mwt_client, __MODULE__, [])[:open] do
      nil ->
        case System.find_executable("xdg-open") do
          nil ->
            {:error, "xdg-open isn't installed, so MWT can't open #{root}: open it yourself."}

          opener ->
            Task.start(fn -> System.cmd(opener, [root], stderr_to_stdout: true) end)
            :ok
        end

      fun ->
        fun.(root)
    end
  end

  @doc "Where the VM keeps all of the workspace's own."
  @spec vm_base() :: Path.t()
  def vm_base, do: @vm_base

  @doc "Why there is no workspace, in words."
  @spec explain(reason()) :: String.t()
  def explain({:foreign, root}),
    do:
      "#{root} is there already, and MWT didn't make it, so it isn't used: move it away, and MWT makes the workspace at the next sync."

  def explain({:failed, root, why}), do: "#{root} couldn't be made: #{why}."
end
