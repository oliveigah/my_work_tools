defmodule MWTClient.Sandbox.CopyBack do
  @moduledoc """
  The workspace's `from-vm/`, copied from the VM onto this machine
  (`MWTClient.Sandbox.Workspace`): the one way the VM writes onto your
  disk without a handoff you land. The VM's copy is the one that counts:
  what it has comes here, what it removed goes here, and a file of yours
  in `from-vm/` is removed too.

  Whatever runs in the VM chooses the bytes, the names and the kinds of
  file. It never chooses where MWT writes, or what runs here. Programs here
  read a new file without a click (a shell prompt runs git where a `.git`
  is, direnv and mise read their files as you `cd` in, a file manager runs
  what is executable, a script globs `*`), so the VM's list is checked
  before anything is written (`check/1`), and one entry breaking a rule
  lands nothing of that copy back:

    * **kinds:** regular files and folders only; a symlink, device, FIFO
      or socket is refused;
    * **names:** each part valid UTF-8 with nothing that doesn't show
      (`MWTClient.Sandbox.Shown`), no control character, not starting with
      `.` or `-` (so never `.` or `..`, `.git` or `.envrc`, nor a file a
      glob turns into an option), at most 255 bytes; not one mise reads
      without a dot (`mise.toml`); at most 32 levels deep and 1024 bytes
      in all;
    * **caps:** 20,000 entries and 1 GiB in all;
    * **real values:** every byte written is looked through for every
      token grant's real value, as a handoff's files are: one found lands
      nothing, and the caller tells the firewall.

  One copy back (`run/4`):

    1. **List** the VM's folder (`find -printf`, bounded as
       `MWTClient.Sandbox.FolderSync`'s list is), and **check** it.
    2. **Compare** it with what was brought last (kept per VM in
       `…/sandbox/sync/`) and with `from-vm/` here, looked at with `lstat`:
       a file is brought again when the VM's changed, or when the one here
       isn't the one MWT wrote.
    3. **Fetch** the changed files as a `tar` the VM writes (`--format=gnu`),
       into a file here under a size limit, and **read** it with
       `MWTClient.Sandbox.TarReader`: only files, each one asked for, into
       a staging folder MWT made (`Workspace.stage/1`), each opened
       exclusively, so never through a link, and looked through as it is
       written. No `tar -x` runs here on the VM's bytes.
    4. **Move** them into place, each with one rename, after making the
       folders the VM has, and removing what it hasn't, each path checked
       with `lstat`, a link removed as a link, never followed. Files are
       0444, folders 0555: a program here that writes into `from-vm/` by
       mistake fails at once, instead of seeing its file go at the next
       copy back.

  A program reading a file sees it whole, old or new; a set of files
  changes one file at a time. The file's time here is when it was written
  here: the VM's only tells what changed.
  """

  alias MWTClient.Sandbox.{Bounded, FolderSync, Secrets, Shown, TarReader, Workspace}

  @max_entries 20_000
  @max_bytes 1024 * 1024 * 1024
  @max_depth 32
  @max_path 1024
  @max_name 255
  # The VM's list: each entry is at most a path and a few numbers.
  @max_list 64 * 1024 * 1024
  # What `from-vm/` here may hold before MWT stops looking: it is MWT's,
  # but you can still put anything in it.
  @max_here 4 * @max_entries
  @fetch_seconds 3_600
  @error_bytes 64 * 1024
  @error_shown 2 * 1024

  # The VM's side, step 1: every path of its folder, with its kind, size,
  # modification time and link target. Made when missing.
  @list ~S"""
  set -e
  mkdir -p -- "$1"
  cd -- "$1"
  find . -mindepth 1 -printf '%y\0%s\0%T@\0%l\0%P\0' 2>/dev/null
  """

  # The VM's side, step 3: the files named on its input, as a tar. tar
  # ends with 1 when a file changed while it read it: it is brought again
  # next time, its time having moved.
  @pack ~S"""
  set -e
  cd -- "$1"
  exec tar -c -f - --format=gnu --null --no-recursion --verbatim-files-from -T -
  """

  # This machine's side of step 3: the list into the VM, the archive into
  # a file, which may grow to at most `MWT_BLOCKS` KiB.
  @fetch ~S"""
  ulimit -f "$MWT_BLOCKS" || exit 1
  "$@" <"$MWT_INPUT" >"$MWT_OUTPUT"
  """

  @typedoc "One path of the VM's folder, as listed (`FolderSync.parse_list/2`)."
  @type entry :: FolderSync.entry()

  @typedoc "What the pages show of the last copy back."
  @type status :: %{
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          synced_at: DateTime.t() | nil,
          changed_at: DateTime.t() | nil,
          error: String.t() | nil,
          written: non_neg_integer(),
          removed: non_neg_integer()
        }

  @typedoc """
  What MWT knows of the copy back for one VM: what it brought, by path,
  as the VM listed it and as it was written here; and the last status.
  """
  @type record :: %{
          vm: String.t(),
          brought: %{binary() => {entry(), term()}} | nil,
          status: status()
        }

  @typedoc "Why a copy back landed nothing."
  @type refusal ::
          {:refused, binary(), String.t()}
          | {:too_big, :entries | :bytes}
          | {:value, String.t(), binary()}
          | {:failed, String.t()}

  @doc "The most a copy back brings: entries, and bytes."
  @spec limits() :: %{entries: pos_integer(), bytes: pos_integer()}
  def limits, do: %{entries: @max_entries, bytes: @max_bytes}

  @doc "A record for a VM nothing was brought from yet."
  @spec new(String.t()) :: record()
  def new(vm) do
    %{
      vm: vm,
      brought: nil,
      status: %{
        files: 0,
        bytes: 0,
        synced_at: nil,
        changed_at: nil,
        error: nil,
        written: 0,
        removed: 0
      }
    }
  end

  @doc """
  One copy back of the VM behind `guest` into the workspace at `root`:
  `{record, nil}` with the record as it is after it (an error in its
  status), or `{record, {:value, grant, path}}` when a file held a grant's
  real value, which the caller tells the firewall of.

  ## Options

    * `:dir` - where what was brought is kept (required);
    * `:secrets` - the real values looked for (`MWTClient.Sandbox.Secrets`);
    * `:progress` - called with each `t:MWTClient.Sandbox.FolderSync.phase/0`.
  """
  @spec run(record(), map(), Path.t(), keyword()) ::
          {record(), nil | {:value, String.t(), binary()}}
  def run(record, guest, root, opts) do
    dir = Keyword.fetch!(opts, :dir)
    secrets = Keyword.get(opts, :secrets)
    progress = Keyword.get(opts, :progress, fn _phase -> :ok end)
    record = with_brought(record, dir, root)
    progress.(:comparing)

    with {:ok, listed} <- listed(guest),
         :ok <- check(listed),
         {:ok, here} <- here(Workspace.from_vm(root)) do
      plan = plan(listed, record.brought, here)
      bytes = Enum.sum_by(plan.bring, &size(listed[&1]))
      if plan.bring != [], do: progress.({:sending, length(plan.bring), bytes})

      case bring(guest, root, plan, listed, secrets) do
        :ok ->
          brought = stamped(Workspace.from_vm(root), listed)
          write_brought(dir, record, root, brought)
          {done(record, listed, brought, plan), nil}

        {:error, {:value, grant, path}} ->
          {failed(record, {:value, grant, path}), {:value, grant, path}}

        {:error, reason} ->
          {failed(record, reason), nil}
      end
    else
      {:error, reason} -> {failed(record, reason), nil}
    end
  end

  defp size({:file, size, _mtime}), do: size
  defp size(_other), do: 0

  defp listed(guest) do
    words = ["bash", "-c", @list, "mwt-copy-back", guest.place.(Workspace.vm_store())]

    case FolderSync.read(guest, words, @max_list) do
      {:ok, output} ->
        case FolderSync.parse_list(output, @max_entries) do
          {:ok, listed} -> {:ok, listed}
          {:error, :too_many} -> {:error, {:too_big, :entries}}
        end

      {:error, text} ->
        {:error, {:failed, "The VM's from-vm couldn't be read: " <> text}}
    end
  end

  @doc """
  Whether the VM's list may come here: `:ok`, or the first path breaking a
  rule and why, or what it holds too much of. In path order, so the same
  list always names the same path.
  """
  @spec check(%{binary() => entry()}) :: :ok | {:error, refusal()}
  def check(listed) do
    bytes = listed |> Map.values() |> Enum.sum_by(&size/1)

    cond do
      map_size(listed) > @max_entries ->
        {:error, {:too_big, :entries}}

      bytes > @max_bytes ->
        {:error, {:too_big, :bytes}}

      true ->
        listed
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.find_value(:ok, fn {path, entry} ->
          case kind(entry) || path_problem(path) do
            nil -> nil
            why -> {:error, {:refused, path, why}}
          end
        end)
    end
  end

  defp kind(:dir), do: nil
  defp kind({:file, _size, _mtime}), do: nil
  defp kind({:link, _target}), do: "it is a symlink: only files and folders come here"

  defp kind(_other),
    do:
      "it isn't a file or a folder (a device, a FIFO or a socket): only files and folders come here"

  @doc """
  What is wrong with `path` as a name here, or nil.

      iex> MWTClient.Sandbox.CopyBack.path_problem("reports/june.pdf")
      nil
      iex> MWTClient.Sandbox.CopyBack.path_problem("x/.git/config")
      "a name starts with a dot: tools here act on such files by being there (.git, .envrc), so none comes here"
      iex> MWTClient.Sandbox.CopyBack.path_problem("--force")
      "a name starts with -: a script here that globs * would take it as an option"
  """
  @spec path_problem(binary()) :: String.t() | nil
  def path_problem(path) do
    parts = :binary.split(path, "/", [:global])

    cond do
      byte_size(path) > @max_path -> "its path is longer than #{@max_path} bytes"
      length(parts) > @max_depth -> "it is more than #{@max_depth} folders deep"
      true -> Enum.find_value(parts, &name_problem/1) || read_by_mise(parts)
    end
  end

  defp name_problem(""), do: "it has an empty name"
  defp name_problem("." <> _), do: "a name starts with a dot: " <> dot_reason()

  defp name_problem("-" <> _),
    do: "a name starts with -: a script here that globs * would take it as an option"

  defp name_problem(name) when byte_size(name) > @max_name,
    do: "a name is longer than #{@max_name} bytes"

  defp name_problem(name) do
    cond do
      not String.valid?(name) ->
        "a name holds bytes that aren't UTF-8"

      name =~ ~r/[\x00-\x1F\x7F]/ ->
        "a name holds a control character"

      Shown.hidden(name) != [] ->
        "a name holds characters that don't show (#{Enum.join(Shown.hidden(name), ", ")})"

      true ->
        nil
    end
  end

  defp dot_reason,
    do: "tools here act on such files by being there (.git, .envrc), so none comes here"

  # mise reads these as you `cd` in, without a dot.
  defp read_by_mise(parts) do
    file = List.last(parts)
    folder = parts |> Enum.drop(-1) |> List.last()

    mise? =
      file == "mise.toml" or Regex.match?(~r/^mise\..+\.toml$/, file) or
        (folder == "mise" and Regex.match?(~r/^config(\..+)?\.toml$/, file))

    if mise?, do: "mise reads a file of that name as you cd in, so it doesn't come here"
  end

  # `from-vm/` here, as `lstat` finds it: folders, files with what tells
  # MWT's own write from another, and anything else.
  defp here(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> walk([{"", root}], %{}, 0)
      _other -> {:error, {:failed, "#{root} isn't a folder"}}
    end
  end

  defp walk([], acc, _count), do: {:ok, acc}

  defp walk([{rel, abs} | rest], acc, count) do
    names =
      case :file.list_dir_all(abs) do
        {:ok, names} -> Enum.map(names, &if(is_list(&1), do: List.to_string(&1), else: &1))
        {:error, _} -> []
      end

    if count + length(names) > @max_here do
      {:error, {:failed, "from-vm here holds more than #{@max_here} files and folders"}}
    else
      {queue, acc} =
        Enum.reduce(names, {rest, acc}, fn name, {queue, acc} ->
          child_rel = if rel == "", do: name, else: rel <> "/" <> name
          child = Path.join(abs, name)

          case stamp(child) do
            :dir -> {[{child_rel, child} | queue], Map.put(acc, child_rel, :dir)}
            other -> {queue, Map.put(acc, child_rel, other)}
          end
        end)

      walk(queue, acc, count + length(names))
    end
  end

  # What a path here is: a folder, a file as MWT would have left it (size,
  # time, inode), or something else.
  defp stamp(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> :dir
      {:ok, %File.Stat{type: :regular} = s} -> {:file, s.size, s.mtime, s.inode, s.mode}
      {:ok, _other} -> :other
      {:error, _} -> nil
    end
  end

  @doc """
  What to bring and what to remove so `from-vm/` here, holding `here`,
  becomes what the VM `listed`. A file comes again when the VM's changed
  since it was `brought`, or when the one here isn't the one MWT wrote.
  """
  @spec plan(map(), map(), map()) :: %{
          bring: [binary()],
          folders: [binary()],
          remove: [binary()]
        }
  def plan(listed, brought, here) do
    bring =
      for {path, {:file, _, _} = entry} <- listed,
          Map.get(brought, path) != {entry, Map.get(here, path)},
          do: path

    folders = for {path, :dir} <- listed, Map.get(here, path) != :dir, do: path

    remove =
      for {path, found} <- here,
          not same_kind?(Map.get(listed, path), found),
          do: path

    %{bring: Enum.sort(bring), folders: Enum.sort_by(folders, &depth/1), remove: remove}
  end

  defp same_kind?(:dir, :dir), do: true
  defp same_kind?({:file, _, _}, {:file, _, _, _, _}), do: true
  defp same_kind?(_listed, _here), do: false

  defp depth(path), do: length(:binary.split(path, "/", [:global]))

  defp bring(guest, root, plan, listed, secrets) do
    stage = Workspace.stage(root)

    with :ok <- fresh(stage) do
      try do
        with :ok <- fetch(guest, stage, plan.bring, listed),
             :ok <- unpack(stage, plan.bring, secrets) do
          move(Workspace.from_vm(root), Path.join(stage, "files"), plan, listed)
        end
      after
        File.rm_rf(stage)
      end
    end
  end

  # The staging folder, empty, MWT's alone: anything in its place goes.
  defp fresh(stage) do
    File.rm_rf(stage)

    with :ok <- File.mkdir(stage),
         :ok <- File.chmod(stage, 0o700),
         :ok <- File.mkdir(Path.join(stage, "files")) do
      :ok
    else
      {:error, reason} ->
        {:error, {:failed, "#{stage} couldn't be made: #{:file.format_error(reason)}"}}
    end
  end

  defp fetch(_guest, _stage, [], _listed), do: :ok

  defp fetch(guest, stage, paths, listed) do
    input = Path.join(stage, "list")
    output = Path.join(stage, "archive.tar")
    File.write!(input, Enum.map(paths, &[&1, 0]))

    # Each file padded to a block, a header and a long name each, and the
    # end: more than that is not what was asked for.
    blocks = Enum.sum_by(paths, &(div(size(listed[&1]) + 511, 512) + 3)) + 20
    kib = div(blocks * 512, 1024) + 1

    words =
      guest.stream.(["bash", "-c", @pack, "mwt-copy-back", guest.place.(Workspace.vm_store())])

    case Bounded.cmd("bash", ["-c", @fetch, "mwt-copy-back" | words],
           max: @error_bytes,
           seconds: @fetch_seconds,
           env:
             [{"MWT_INPUT", input}, {"MWT_OUTPUT", output}, {"MWT_BLOCKS", "#{kib}"}] ++ guest.env
         ) do
      {:ok, _output, _errors, status} when status in [0, 1] ->
        :ok

      {:ok, output, errors, status} ->
        detail = output |> Bounded.failure(errors, @error_bytes) |> error_text()

        why =
          if status == 128 + 25,
            do: "it was larger than the files asked for",
            else: "exit #{status}: #{detail}"

        {:error, {:failed, "The files couldn't be fetched from the VM: " <> why}}

      {:error, :timeout} ->
        {:error, {:failed, "The files couldn't be fetched from the VM in #{@fetch_seconds} s"}}

      {:error, {:too_long, _head}} ->
        {:error, {:failed, "The VM's tar printed more than 64 KiB of errors"}}
    end
  end

  # The archive, read here: each file one that was asked for, once, written
  # under the staging folder and looked through as it goes.
  defp unpack(_stage, [], _secrets), do: :ok

  defp unpack(stage, paths, secrets) do
    archive = Path.join(stage, "archive.tar")
    files = Path.join(stage, "files")

    case File.open(archive, [:read, :raw, :binary, read_ahead: 1024 * 1024]) do
      {:ok, io} ->
        try do
          entries(io, files, MapSet.new(paths), secrets, @max_bytes)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:failed, "The archive couldn't be read: #{:file.format_error(reason)}"}}
    end
  end

  defp entries(io, files, wanted, secrets, budget) do
    case TarReader.next(io) do
      :eof ->
        case Enum.sort(wanted) do
          [] -> :ok
          [first | _] -> {:error, {:failed, "#{first} didn't come from the VM: sync again"}}
        end

      {:file, name, size} ->
        cond do
          not MapSet.member?(wanted, name) ->
            {:error, {:failed, "the VM sent a file that wasn't asked for"}}

          size > budget ->
            {:error, {:too_big, :bytes}}

          true ->
            with :ok <- write(io, files, name, size, secrets) do
              entries(io, files, MapSet.delete(wanted, name), secrets, budget - size)
            end
        end

      {:dir, _name} ->
        {:error, {:failed, "the VM sent a folder where files were asked for"}}

      {:error, why} ->
        {:error, {:failed, "The VM's archive couldn't be read: " <> why}}
    end
  end

  # One file into the staging folder: its folders made there (MWT's own,
  # with names already checked), the file opened exclusively, its bytes
  # looked through for real values with the end of the chunk before.
  defp write(io, files, name, size, secrets) do
    path = Path.join(files, name)
    keep = max(Secrets.longest(secrets) - 1, 0)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, out} <- File.open(path, [:write, :exclusive, :raw, :binary]) do
      try do
        result =
          TarReader.data(io, size, "", fn chunk, tail ->
            seen = tail <> chunk

            case Secrets.find(secrets, seen) do
              {:value, grant} ->
                {:halt, {:value, grant}}

              _none ->
                case :file.write(out, chunk) do
                  :ok ->
                    from = max(byte_size(seen) - keep, 0)
                    {:cont, binary_part(seen, from, byte_size(seen) - from)}

                  {:error, reason} ->
                    {:halt, {:write, reason}}
                end
            end
          end)

        case result do
          {:ok, _tail} ->
            :ok

          {:halt, {:value, grant}} ->
            {:error, {:value, grant, name}}

          {:halt, {:write, reason}} ->
            {:error, {:failed, "#{name} couldn't be written: #{:file.format_error(reason)}"}}

          {:error, why} ->
            {:error, {:failed, "The VM's archive couldn't be read: " <> why}}
        end
      after
        File.close(out)
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:failed, "#{name} couldn't be staged: #{:file.format_error(reason)}"}}
    end
  end

  # Into place: every folder of `from-vm/` writable for as long as it
  # takes, the ones the VM removed too (a file is unlinked from a folder
  # only while it is writable), what the VM hasn't removed, its folders
  # made, each file renamed over what is there; then folders 0555 again.
  defp move(here, staged, plan, listed) do
    kept = for {path, :dir} <- listed, do: path
    folders = [here | Enum.map(kept ++ plan.remove, &Path.join(here, &1))]

    try do
      Enum.each(folders, &chmod_folder(&1, 0o755))

      with :ok <- each_ok(Enum.sort_by(plan.remove, &(-depth(&1))), &remove(here, &1)),
           :ok <- each_ok(plan.folders, &folder(here, &1)),
           :ok <- each_ok(plan.bring, &place(here, staged, &1)) do
        :ok
      end
    after
      Enum.each(folders, &chmod_folder(&1, 0o555))
    end
  end

  # What the VM hasn't: a folder with all it holds, anything else as
  # itself, a link never followed.
  defp remove(here, path) do
    full = Path.join(here, path)

    removed =
      case File.lstat(full) do
        {:ok, %File.Stat{type: :directory}} -> File.rm_rf(full)
        {:ok, _other} -> File.rm(full)
        {:error, _gone} -> :ok
      end

    case removed do
      :ok -> :ok
      {:ok, _paths} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason, _path} -> cannot_remove(path, reason)
      {:error, reason} -> cannot_remove(path, reason)
    end
  end

  defp cannot_remove(path, reason),
    do: {:error, {:failed, "#{path} couldn't be removed here: #{:file.format_error(reason)}"}}

  # Only a real folder: a link in its place leads out of `from-vm/`.
  defp chmod_folder(path, mode) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> File.chmod(path, mode)
      _other -> :ok
    end
  end

  defp each_ok(items, fun), do: Enum.find_value(items, :ok, &with(:ok <- fun.(&1), do: nil))

  # A folder the VM has: one here already stays; anything else in its
  # place goes (removed above), and the parent is a real folder MWT made.
  defp folder(here, path) do
    full = Path.join(here, path)

    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _other} ->
        File.rm(full)
        mkdir(full, path)

      {:error, :enoent} ->
        mkdir(full, path)

      {:error, reason} ->
        {:error, {:failed, "#{path} couldn't be made: #{:file.format_error(reason)}"}}
    end
  end

  defp mkdir(full, path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.dirname(full)),
         :ok <- File.mkdir(full),
         :ok <- File.chmod(full, 0o755) do
      :ok
    else
      _failed -> {:error, {:failed, "#{path} couldn't be made"}}
    end
  end

  defp place(here, staged, path) do
    from = Path.join(staged, path)
    to = Path.join(here, path)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.dirname(to)),
         :ok <- clear(to),
         :ok <- File.chmod(from, 0o444),
         :ok <- File.rename(from, to) do
      :ok
    else
      _failed -> {:error, {:failed, "#{path} couldn't be written: sync again"}}
    end
  end

  # A folder in the way of a file goes; a file or link is renamed over.
  defp clear(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> with({:ok, _} <- File.rm_rf(path), do: :ok)
      _other -> :ok
    end
  end

  # What was brought: each file the VM listed, as it listed it and as it
  # is here now.
  defp stamped(here, listed) do
    for {path, {:file, _, _} = entry} <- listed, into: %{} do
      {path, {entry, stamp(Path.join(here, path))}}
    end
  end

  defp done(record, listed, brought, plan) do
    now = DateTime.utc_now()
    changed? = plan.bring != [] or plan.remove != [] or plan.folders != []

    status = %{
      record.status
      | files: map_size(brought),
        bytes: listed |> Map.values() |> Enum.sum_by(&size/1),
        synced_at: now,
        changed_at: if(changed?, do: now, else: record.status.changed_at),
        error: nil,
        written: length(plan.bring),
        removed: length(plan.remove)
    }

    %{record | brought: brought, status: status}
  end

  defp failed(record, reason),
    do: %{record | status: %{record.status | error: explain(reason), written: 0, removed: 0}}

  @doc "Why a copy back landed nothing, in words."
  @spec explain(refusal()) :: String.t()
  def explain({:refused, path, why}),
    do: "Nothing of from-vm came: #{Shown.text(path)} isn't taken, since #{why}."

  def explain({:too_big, :entries}),
    do: "Nothing of from-vm came: it holds more than #{@max_entries} files and folders."

  def explain({:too_big, :bytes}),
    do: "Nothing of from-vm came: it holds more than #{div(@max_bytes, 1024 * 1024 * 1024)} GiB."

  def explain({:value, grant, path}),
    do:
      "Nothing of from-vm came: #{Shown.text(path)} holds #{grant}'s real value, which nothing in the VM should have. Replace that credential at its service."

  def explain({:failed, text}), do: error_text(text)

  defp error_text(text), do: text |> Shown.text() |> Bounded.brief(@error_shown)

  # What was brought: from memory, else from the file kept for this VM and
  # workspace, else nothing, and then everything comes again.
  defp with_brought(%{brought: brought} = record, _dir, _root) when is_map(brought), do: record

  defp with_brought(record, dir, root) do
    brought =
      with {:ok, bytes} <- File.read(brought_file(dir)),
           %{vm: vm, root: ^root, brought: brought} when vm == record.vm and is_map(brought) <-
             :erlang.binary_to_term(bytes, [:safe]) do
        brought
      else
        _ -> %{}
      end

    %{record | brought: brought}
  rescue
    ArgumentError -> %{record | brought: %{}}
  end

  defp brought_file(dir), do: Path.join([dir, "sync", "copy-back.bin"])

  defp write_brought(dir, record, root, brought) do
    path = brought_file(dir)
    File.mkdir_p!(Path.dirname(path))
    temporary = "#{path}.#{System.unique_integer([:positive])}"
    term = %{vm: record.vm, root: root, brought: brought}
    File.write!(temporary, :erlang.term_to_binary(term, [:compressed]))
    File.rename!(temporary, path)
  end
end
