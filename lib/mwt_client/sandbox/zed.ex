defmodule MWTClient.Sandbox.Zed do
  @moduledoc """
  Opens a folder of the VM in Zed on your machine, in the Zed window
  already connected to the VM when there is one: beside the projects it
  holds (a Zed window keeps several, in its sidebar), leaving them and
  their agent threads alone.

  Zed (1.28) does that for folders of your machine with `zed --existing`,
  but not for an `ssh://` address: there it only brings forward a window
  that has the very folder open, and opens a new one for any other. Its
  `--reuse` does open the address in the first window connected to the
  same host, as a new project in its sidebar, but checks nothing: a folder
  already open there would be opened twice. So MWT looks in the VM first
  (`opened/1`) and picks (`args/2`):

    * the folder is open in Zed: `--existing`, which brings it forward;
    * Zed is connected to the VM, without the folder: `--reuse`;
    * Zed isn't connected, or MWT can't tell: `--existing`, a new window.

  `--reuse` is left out of `zed --help`, and what `opened/1` reads is how
  Zed's server works inside, not a promise: if either changes, the folder
  opens in a new window, as before. With Zed's agent features off, a Zed
  window holds one project, and `--reuse` replaces it.

  Zed is started in a session of its own, with nothing tying it to MWT, so
  a Zed that MWT started keeps running when MWT restarts or quits.

  Zed reaches the VM through the `mwt-sandbox` entry in `~/.ssh/config`,
  which the Setup page writes out; MWT only opens it when that entry runs
  this identity's launcher (`MWTClient.Sandbox.Msb.ssh_entry/2`), so Zed
  never lands in a VM MWT doesn't run.

  Tests set `config :mwt_client, MWTClient.Sandbox.Zed, open: fun`, a
  function of the username and the address, to see the address instead of
  starting Zed.
  """

  alias MWTClient.Sandbox.{Guest, Msb}

  @ssh_host "mwt-sandbox"

  @type error :: :no_zed | :no_ssh_entry | {:other_ssh_entry, String.t()} | String.t()

  @typedoc """
  What Zed has open in the VM: whether a Zed window is connected to it,
  and the folders the servers of the projects connected hold open (each
  project's folders, and some of Zed's own); `:unknown` when MWT couldn't
  look.
  """
  @type opened :: %{connected?: boolean(), folders: [Path.t()]} | :unknown

  @doc "The host name the VM has in your SSH config."
  @spec ssh_host() :: String.t()
  def ssh_host, do: @ssh_host

  @doc "The address Zed opens a folder of the VM at."
  @spec url(Path.t()) :: String.t()
  def url(folder), do: "ssh://#{@ssh_host}#{folder}"

  @doc "The command that opens `folder` in Zed, for you to copy."
  @spec command(Path.t()) :: String.t()
  def command(folder), do: "zed #{url(folder)}"

  @doc """
  Whether `folder` may go into Zed's address: a path under `root`, the
  VM's `/work`, of letters, digits and `._+@~-`, with no `.` or `..` step.
  The address is the host's name followed by the path, so a path that
  doesn't start with `/` names another host (`.evil.example/x` gives
  `ssh://mwt-sandbox.evil.example/x`), and one with `?`, `#` or a space
  says something else than the folder. The paths of the VM's worktrees
  are what git there prints, so the VM chooses them.
  """
  @spec folder?(String.t(), Path.t()) :: boolean()
  def folder?(folder, root) when is_binary(folder) do
    String.starts_with?(folder, root <> "/") and
      Regex.match?(~r"\A(/[\p{L}\p{N}._+@~-]+)+\z"u, folder) and
      not Enum.any?(Path.split(folder), &(&1 in [".", ".."]))
  end

  def folder?(_folder, _root), do: false

  @doc "Opens `folder` of the VM in Zed, looking first at what Zed has open in `guest`, the VM."
  @spec open(String.t(), Path.t(), Guest.t()) :: :ok | {:error, error()}
  def open(username, folder, guest) do
    cond do
      not folder?(folder, guest.root) ->
        {:error, "MWT opens only folders under #{guest.root} in Zed, named in plain characters."}

      fun = Application.get_env(:mwt_client, __MODULE__, [])[:open] ->
        fun.(username, url(folder))

      true ->
        launch(username, folder, guest)
    end
  end

  defp launch(username, folder, guest) do
    with :ok <- entry(username),
         zed when is_binary(zed) <- executable() || {:error, :no_zed} do
      args = args(folder, opened(guest))
      {program, args} = command_line(zed, args, MWTClient.Executable.find("setsid"))
      # Zed's command hands the address to Zed and returns; one that starts
      # Zed stays with it, so it is not waited on.
      Task.start(fn -> System.cmd(program, args, stderr_to_stdout: true) end)
      :ok
    end
  end

  @doc """
  The arguments to `zed` that open `folder`, given what Zed has open in
  the VM: `--reuse` only when a Zed window is connected to it and no
  project connected has the folder open; `--existing` otherwise.
  """
  @spec args(Path.t(), opened()) :: [String.t()]
  def args(folder, %{connected?: true, folders: folders}) do
    if folder in folders,
      do: ["--existing", url(folder)],
      else: ["--reuse", url(folder)]
  end

  def args(folder, _opened), do: ["--existing", url(folder)]

  # Zed's server in the VM, `~/.zed_server/zed-remote-server-…`, runs as
  # one `run` process per project, which keeps each of the project's
  # folders open, and one `proxy` process per connection to it, which
  # lives as long as Zed's window is connected. Both name the project:
  # `proxy --identifier ID`, and `run … --pid-file …/ID/server.pid`.
  # Processes are matched on the program they run, so this script's own
  # text, which names them too, never is.
  #
  # It runs on every look at the Projects page's slots and on every `mwt
  # project`, so it forks little: one grep finds the few processes that
  # name Zed's server among the hundreds the VM runs, and one find lists
  # each `run` process's open files. A fork per process and per open file
  # took 3 s with a few Zed windows open (2026-11-15); this takes 0.15 s.
  @opened_script ~S"""
  IFS='
  '
  for f in $(grep -l -a -F zed-remote-server /proc/[0-9]*/cmdline 2>/dev/null); do
    p=${f%/cmdline}
    # Split on newlines only, with no globbing of the words.
    set -f
    set -- $(tr '\0' '\n' < "$f" 2>/dev/null)
    set +f
    case "$1" in *zed-remote-server*) ;; *) continue ;; esac
    case "$2" in
      proxy) [ "$3" = --identifier ] && printf 'connected %s\n' "$4" ;;
      run)
        id=
        while [ $# -gt 1 ]; do
          [ "$1" = --pid-file ] && id=${2%/*} && id=${id##*/}
          shift
        done
        [ -n "$id" ] || continue
        find "$p/fd/" -mindepth 1 -maxdepth 1 -printf '%l\n' 2>/dev/null |
          while IFS= read -r t; do
            [ -d "$t" ] && printf 'open %s %s\n' "$id" "$t"
          done
        ;;
    esac
  done
  exit 0
  """

  @doc "What Zed has open in `guest`, the VM (see the module's notes)."
  @spec opened(Guest.t()) :: opened()
  def opened(guest) do
    case guest.exec.(["/bin/sh", "-c", @opened_script]) do
      {:ok, output} -> parse_opened(output)
      {:error, _} -> :unknown
    end
  end

  defp parse_opened(output) do
    lines = Enum.map(String.split(output, "\n", trim: true), &String.split(&1, " ", parts: 3))
    connected = for ["connected", id] <- lines, into: MapSet.new(), do: id

    %{
      connected?: MapSet.size(connected) > 0,
      folders:
        for(["open", id, folder] <- lines, MapSet.member?(connected, id), do: folder)
        |> Enum.uniq()
    }
  end

  @doc """
  The program and arguments that run the `zed` command at `zed` with
  `args`: in its own session through `setsid`, when there is one, with no
  output tied to MWT.
  """
  @spec command_line(Path.t(), [String.t()], Path.t() | nil) :: {Path.t(), [String.t()]}
  def command_line(zed, args, nil), do: {zed, args}

  def command_line(zed, args, setsid) do
    # The shell redirects Zed's output away from MWT's pipe and returns at
    # once: `setsid -f` forks Zed off into a session of its own.
    {"/bin/sh", ["-c", ~s(exec "$0" -f "$@" </dev/null >/dev/null 2>&1), setsid, zed | args]}
  end

  defp entry(username) do
    case Msb.ssh_entry(username, @ssh_host) do
      :ok -> :ok
      :missing -> {:error, :no_ssh_entry}
      {:other, command} -> {:error, {:other_ssh_entry, command}}
    end
  end

  # A desktop app may not have your shell's PATH.
  defp executable do
    Enum.find_value(["zed", "zeditor", "zed-editor"], &MWTClient.Executable.find/1) ||
      Enum.find(
        [
          Path.expand("~/.local/bin/zed"),
          "/usr/bin/zeditor",
          "/var/lib/flatpak/exports/bin/dev.zed.Zed"
        ],
        &File.regular?/1
      )
  end

  @doc "Why Zed didn't open, in words."
  @spec explain(error()) :: String.t()
  def explain(:no_zed), do: "MWT can't find Zed's zed command on this machine."

  def explain(:no_ssh_entry),
    do:
      "Zed can't reach the VM yet: add the mwt-sandbox entry from the Setup page to ~/.ssh/config."

  def explain({:other_ssh_entry, _command}),
    do:
      "The mwt-sandbox entry in ~/.ssh/config reaches another VM. Use the one on the Setup page."

  def explain(text) when is_binary(text), do: text
end
