defmodule MWTClient.Sandbox.Confine do
  @moduledoc """
  The bubble a confined command subgrant runs in, on this machine: `bwrap`,
  as the VM's own bubble is (`MWTClient.Sandbox.Bubble`), but around one
  script of yours instead of the VM.

    * user, PID, IPC, UTS and cgroup namespaces of its own; the network is
      shared, since a script may need your VPN. With its PID namespace,
      what the command started ends with it, even a process that left its
      process group (`setsid`), which a run as you can't reach
      (`MWTClient.Sandbox.HostRun`): every process of a PID namespace ends
      when its first one does;
    * the system's folders read-only (`/usr`, `/etc`, and `/opt`, `/nix`
      and `/snap` where they exist), with the folder `/etc/resolv.conf`
      leads to, often under `/run`, so names resolve;
    * an empty home, on tmpfs, at your home's path; the folders of it you
      let commands read (`reads`: where your tools live), read-only, each
      with what it links to one level down;
    * the command's folder, read-only unless the subgrant may write there;
      one that runs in your home folder runs in the empty one;
    * the workspace (`MWTClient.Sandbox.Workspace`): its `from-vm/`
      read-only, what the VM left there, and its `to-vm/` writable, the
      one folder outside its own a confined command may write to, for the
      VM to read;
    * `/mnt/mwt/tokens`, where the token files of the grants it runs with
      are written, as in the VM, so a script reads them the same way on
      both sides;
    * nothing of MWT's environment: `MWTClient.Sandbox.HostRun` gives it
      only what it should have.

  `timeout` stays outside `bwrap`, so the process group it kills is still
  the whole command. There is no silent fallback: where `bwrap` can't make
  the bubble, a confined command doesn't run, and says why (`available/0`).

  `words/1` is pure: the arguments, up to and including `--`.
  """

  alias MWTClient.Sandbox.Workspace

  @system ~w(/opt /nix /snap)

  @type spec :: %{
          required(:dir) => Path.t(),
          required(:writes) => boolean(),
          required(:home) => Path.t(),
          required(:reads) => [Path.t()],
          optional(:workspace) => Path.t() | nil,
          optional(:bwrap) => String.t(),
          optional(:resolver) => Path.t() | nil,
          optional(:links) => %{Path.t() => Path.t()}
        }

  @doc """
  The `bwrap` arguments for `spec`, up to and including `--`. `links` maps
  a folder of `reads` to the folder it links to, which is bound too;
  `resolver` is the folder `/etc/resolv.conf` leads to, or nil.

      iex> words = MWTClient.Sandbox.Confine.words(%{dir: "/home/me/site", writes: false,
      ...>   home: "/home/me", reads: ["/home/me/.local/bin"], bwrap: "bwrap"})
      iex> Enum.take(words, 3)
      ["bwrap", "--unshare-user", "--unshare-pid"]
      iex> Enum.chunk_every(words, 3, 1) |> Enum.member?(["--tmpfs", "/home/me", "--ro-bind-try"])
      true
      iex> Enum.slice(words, -6, 6)
      ["--ro-bind", "/home/me/site", "/home/me/site", "--chdir", "/home/me/site", "--"]
  """
  @spec words(spec()) :: [String.t()]
  def words(spec) do
    links = Map.get(spec, :links, %{})

    reads =
      Enum.flat_map(spec.reads, fn folder ->
        ["--ro-bind-try", folder, folder] ++
          case links do
            %{^folder => target} -> ["--ro-bind-try", target, target]
            _none -> []
          end
      end)

    [Map.get(spec, :bwrap) || bwrap() || "bwrap"] ++
      ~w(--unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup --die-with-parent) ++
      ["--ro-bind", "/usr", "/usr"] ++
      usr_links() ++
      ["--ro-bind", "/etc", "/etc"] ++
      Enum.flat_map(@system, &["--ro-bind-try", &1, &1]) ++
      ~w(--proc /proc --dev /dev --tmpfs /tmp --tmpfs /run) ++
      resolver(Map.get(spec, :resolver)) ++
      ["--tmpfs", spec.home] ++
      reads ++
      workspace(Map.get(spec, :workspace)) ++
      ["--dir", "/mnt/mwt/tokens"] ++
      folder(spec) ++
      ["--chdir", spec.dir, "--"]
  end

  # The command's own folder comes after, so a subgrant that runs in a half
  # keeps the mode it was given there.
  defp workspace(nil), do: []

  defp workspace(root) do
    ["--ro-bind-try", Workspace.from_vm(root), Workspace.from_vm(root)] ++
      ["--bind-try", Workspace.to_vm(root), Workspace.to_vm(root)]
  end

  # Its folder; your home itself is the empty one, never yours.
  defp folder(%{dir: home, home: home}), do: []
  defp folder(spec), do: [if(spec.writes, do: "--bind", else: "--ro-bind"), spec.dir, spec.dir]

  defp resolver(nil), do: []
  defp resolver(folder), do: ["--ro-bind-try", folder, folder]

  # /bin, /lib and the like: links into /usr where the system merged them,
  # else folders of their own, read-only.
  defp usr_links do
    Enum.flat_map(~w(bin sbin lib lib64), fn name ->
      path = "/" <> name

      case File.read_link(path) do
        {:ok, target} -> ["--symlink", target, path]
        {:error, _} -> ["--ro-bind-try", path, path]
      end
    end)
  end

  @doc "The `bwrap` a confined command runs in: the bubble's own, else the system's."
  @spec bwrap() :: String.t() | nil
  def bwrap, do: MWTClient.Sandbox.Bubble.bwrap()

  @doc """
  The folder `/etc/resolv.conf` leads to when it is a link (often under
  `/run`, which the bubble replaces), so it can be bound; nil otherwise.
  """
  @spec resolver() :: Path.t() | nil
  def resolver do
    case File.read_link("/etc/resolv.conf") do
      {:ok, target} -> target |> Path.expand("/etc") |> Path.dirname()
      {:error, _} -> nil
    end
  end

  @doc """
  What each folder of `reads` links to, one level down, for the folders
  that are links: version managers keep tools under your home, behind
  them.
  """
  @spec links([Path.t()]) :: %{Path.t() => Path.t()}
  def links(reads) do
    for folder <- reads,
        {:ok, target} <- [File.read_link(folder)],
        into: %{},
        do: {folder, Path.expand(target, Path.dirname(folder))}
  end

  @doc """
  The folders of `home` a login shell's `path` runs tools from: what
  commands may read when you haven't said otherwise.

      iex> MWTClient.Sandbox.Confine.reads_from_path("/home/me/.local/bin:/usr/bin:/home/me/.cargo/bin:/home/me", "/home/me")
      ["/home/me/.local/bin", "/home/me/.cargo/bin"]
  """
  @spec reads_from_path(String.t(), Path.t()) :: [Path.t()]
  def reads_from_path(path, home) do
    path
    |> String.split(":", trim: true)
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&String.starts_with?(&1, String.trim_trailing(home, "/") <> "/"))
    |> Enum.uniq()
  end

  @doc """
  Whether a confined command can run here: `:ok`, or why not. Makes a
  bubble with the same namespaces and runs `true` in it.
  """
  @spec available() :: :ok | {:error, String.t()}
  def available do
    case bwrap() do
      nil ->
        {:error, "bwrap isn't installed (package bubblewrap)."}

      bwrap ->
        args =
          ~w(--unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup) ++
            ["--ro-bind", "/usr", "/usr"] ++
            usr_links() ++ ~w(--proc /proc --dev /dev -- true)

        case System.cmd(bwrap, args, stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          {output, _status} ->
            {:error, "bwrap can't make the bubble here: " <> String.trim(output)}
        end
    end
  rescue
    error -> {:error, "bwrap can't run here: " <> Exception.message(error)}
  end
end
