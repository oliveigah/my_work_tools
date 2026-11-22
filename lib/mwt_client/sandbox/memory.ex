defmodule MWTClient.Sandbox.Memory do
  @moduledoc """
  The VM's own OptMem, at `/root/.optmem` on a disk of its own
  (`MWTClient.Sandbox.Disks`), and its round trip with yours. Nothing of it
  is on this machine: MWT reaches it through the running VM only, with
  `msb exec` (the guest map, `MWTClient.Sandbox.Guest`).

    * The `memo` tool and an empty memory are put there by the VM itself,
      after each boot (`priv/sandbox/mwt-boot`), from `/mnt/mwt/bin/memo`.
    * `fetch/2` - what the VM noted from a position on: its `LOG.txt`, read
      through the VM, at most 64 MiB of it, as data. The log is memo's
      fixed 320-byte records (position is identity), so a record the VM is
      still writing, short of 320 bytes, is left out, and the number of
      entries is bounded by the size. At most 1,000 are taken at a time,
      each made to show everything it holds (`MWTClient.Sandbox.Shown`):
      what you keep goes into the memory your agents read.
    * `seed/3` - replaces the VM's memory with a copy of yours (`LOG.txt`,
      `TREE/`, `config`: what `memo sync` shares), taken under memo's lock
      here and swapped in under memo's lock there, so it works while agents
      in the VM note things. What the VM had is moved aside, never deleted.
      Given the size of the VM's log when you reviewed it, it refuses when
      the VM noted more since, so nothing unreviewed is moved aside unseen.
    * `bring_back/1` - adds chosen entries to your memory with `memo note`.
    * `move_in/2` - a VM made before 2026-11-16 kept its memory in a folder
      of this machine; the first start of one with the disk copies it in.

  MWT never runs anything from the VM's memory.
  """

  alias MWTClient.Sandbox.{FolderSync, Scratch, Shown}

  @vm "/root/.optmem"
  @shared ["LOG.txt", "TREE", "config"]
  @max_log 64 * 1024 * 1024
  # memo's LOG_REC: each memory is one record of this many bytes, padded
  # with spaces and ended by a newline.
  @record 320
  @review_limit 1_000
  @moved_on "mwt: the VM noted more meanwhile"

  # Run in the VM by python3, which memo needs anyway: under memo's own
  # lock, the VM's memory moves aside and the copy in `memory.incoming`
  # takes its place, part by part, in the same folder, so the lock file
  # stays where memo looks for it.
  @swap ~S"""
  import fcntl, os, shutil, sys
  root, stamp, expect, moved_on = sys.argv[1:5]
  memory = os.path.join(root, "memory")
  incoming = os.path.join(root, "memory.incoming")
  names = ["LOG.txt", "TREE", "config"]
  os.makedirs(memory, exist_ok=True)
  with open(os.path.join(memory, ".lock"), "a") as lock:
      fcntl.flock(lock, fcntl.LOCK_EX)
      log = os.path.join(memory, "LOG.txt")
      size = os.path.getsize(log) if os.path.exists(log) else 0
      if expect and str(size) != expect:
          print(moved_on)
          sys.exit(3)
      if any(os.path.lexists(os.path.join(memory, n)) for n in names):
          before = base = os.path.join(root, "memory.before-" + stamp)
          n = 2
          while os.path.lexists(before):
              before, n = base + "-" + str(n), n + 1
          os.makedirs(before)
          for name in names:
              if os.path.lexists(os.path.join(memory, name)):
                  os.rename(os.path.join(memory, name), os.path.join(before, name))
      for name in names:
          if os.path.lexists(os.path.join(incoming, name)):
              os.rename(os.path.join(incoming, name), os.path.join(memory, name))
  shutil.rmtree(incoming, ignore_errors=True)
  """

  @type entry :: %{index: non_neg_integer(), id: String.t(), date: String.t(), text: String.t()}

  @typedoc """
  What `fetch/2` found: the entries from the position asked, at most
  `review_limit/0` of them; the position after the last one taken
  (`upto`); how many complete records follow it, not taken (`more`); and
  the log's size in bytes.
  """
  @type fetched :: %{
          entries: [entry()],
          upto: non_neg_integer(),
          more: non_neg_integer(),
          size: non_neg_integer()
        }

  @doc "The most entries `fetch/2` takes at a time."
  @spec review_limit() :: pos_integer()
  def review_limit, do: @review_limit

  @doc "Where the VM keeps its memory."
  @spec vm_path() :: Path.t()
  def vm_path, do: @vm

  @doc "Your `memo` tool, or nil when OptMem isn't installed here."
  @spec host_memo() :: Path.t() | nil
  def host_memo do
    path = Path.join(System.user_home!(), ".optmem/memo")
    if File.regular?(path, [:raw]), do: path
  end

  @doc "Your memory's folder."
  @spec host_memory() :: Path.t()
  def host_memory,
    do: System.get_env("MEMORY_DIR") || Path.join(System.user_home!(), ".optmem/memory")

  @doc "Whether you have a memory to copy from."
  @spec host_memory?() :: boolean()
  def host_memory?, do: host_memo() != nil and File.regular?(Path.join(host_memory(), "LOG.txt"))

  @doc """
  The VM's memories from position `from` on (0 is the first), read through
  the VM behind `guest`. A VM with no memory yet has none.
  """
  @spec fetch(map(), non_neg_integer()) :: {:ok, fetched()} | {:error, String.t()}
  def fetch(guest, from) do
    log = guest.place.(Path.join([@vm, "memory", "LOG.txt"]))
    words = ["sh", "-c", ~s([ ! -f "$1" ] || cat -- "$1"), "mwt-memory", log]

    case FolderSync.read(guest, words, @max_log) do
      {:ok, content} ->
        total = div(byte_size(content), @record)
        start = min(from, total)
        upto = min(total, start + @review_limit)

        entries =
          for index <- start..(upto - 1)//1,
              entry <- [entry(content, index)],
              entry != nil,
              do: entry

        {:ok, %{entries: entries, upto: upto, more: total - upto, size: byte_size(content)}}

      {:error, message} ->
        {:error, "The VM's memory couldn't be read: " <> message}
    end
  end

  @doc """
  Replaces the VM's memory with a copy of yours, through the VM behind
  `guest`, and returns how many memories the copy holds: the seed point,
  after which the VM's own notes start. With `expect`, the size `fetch/2`
  found, it changes nothing and says `:moved_on` when the VM's log is no
  longer that size.
  """
  @spec seed(map(), non_neg_integer() | nil, Path.t()) ::
          {:ok, non_neg_integer()} | {:error, :moved_on | String.t()}
  def seed(guest, expect \\ nil, source \\ host_memory()) do
    with {:ok, copy, count} <- snapshot(source) do
      incoming = Path.join(@vm, "memory.incoming")

      try do
        with {:ok, _} <- guest.exec.(["rm", "-rf", "--", guest.place.(incoming)]),
             :ok <- FolderSync.copy(copy, guest, incoming),
             :ok <- swap(guest, expect) do
          {:ok, count}
        else
          {:error, :moved_on} -> {:error, :moved_on}
          {:error, message} -> {:error, "Copying your memory into the VM failed: #{message}"}
        end
      after
        File.rm_rf(Path.dirname(copy))
      end
    end
  end

  # Your memory as it is under memo's lock: memo holds .lock while it reads
  # or writes, so a copy under it never catches a note half written.
  defp snapshot(source) do
    if File.regular?(Path.join(source, "LOG.txt")) do
      # Where only you can read it: it is your memory.
      dir = Scratch.dir!("mwt-memory")
      copy = Path.join(dir, "memory")
      File.mkdir!(copy)

      parts =
        for name <- @shared, File.exists?(Path.join(source, name)), do: Path.join(source, name)

      case MWTClient.Executable.cmd(
             "flock",
             [Path.join(source, ".lock"), "cp", "-a" | parts] ++ [copy],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          {:ok, copy, div(File.stat!(Path.join(copy, "LOG.txt")).size, @record)}

        {output, status} ->
          File.rm_rf(dir)
          {:error, "copying your memory failed (#{status}): #{String.trim(output)}"}
      end
    else
      {:error, "there is no OptMem memory at #{source} to copy"}
    end
  end

  defp swap(guest, expect) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S")
    args = [guest.place.(@vm), stamp, to_string(expect || ""), @moved_on]

    case guest.exec.(["python3", "-c", @swap | args]) do
      {:ok, _} ->
        :ok

      {:error, text} ->
        if String.contains?(text, @moved_on), do: {:error, :moved_on}, else: {:error, text}
    end
  end

  @doc """
  Copies the VM's memory, kept in `folder` here by a VM made before
  2026-11-16, into the VM behind `guest`, when the VM has none of its own
  yet (no log, or an empty one). The folder is then renamed aside, kept.
  """
  @spec move_in(map(), Path.t()) :: :moved | :none | {:error, String.t()}
  def move_in(guest, folder) do
    log = guest.place.(Path.join([@vm, "memory", "LOG.txt"]))

    with true <- File.regular?(Path.join([folder, "memory", "LOG.txt"])),
         {:ok, "none" <> _} <-
           guest.exec.(["sh", "-c", ~s([ -s "$1" ] && echo there || echo none), "mwt", log]),
         :ok <- FolderSync.copy(folder, guest, @vm) do
      stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S")
      File.rename!(folder, "#{folder}.moved-#{stamp}")
      :moved
    else
      false -> :none
      {:ok, _there} -> :none
      {:error, message} -> {:error, "Moving the VM's memory onto its disk failed: #{message}"}
    end
  end

  @doc """
  Adds each text to your memory with `memo note`, in order. Returns one
  result per text: `:ok`, or memo's own words when it refuses (too long,
  for one).
  """
  @spec bring_back([String.t()]) :: [:ok | {:error, String.t()}]
  def bring_back(texts) do
    case host_memo() do
      nil ->
        Enum.map(texts, fn _ -> {:error, "OptMem isn't installed on this machine."} end)

      memo ->
        Enum.map(texts, fn text ->
          case System.cmd(memo, ["note", text], stderr_to_stdout: true) do
            {_, 0} -> :ok
            {output, _} -> {:error, output |> String.trim() |> String.slice(0, 300)}
          end
        end)
    end
  end

  # Memory `index` of the log, as memo slices it: by bytes, its padding and
  # newline dropped. A blank record is no memory. Its text is the VM's, so
  # it is made to show all it holds, and copied out of the log.
  defp entry(content, index) do
    line = Regex.replace(~r/\s+\z/, binary_part(content, index * @record, @record), "")

    case Regex.run(~r/\A#(\d+) (\d{4}-\d{2}-\d{2}) (.*)\z/s, line) do
      _blank when line == "" ->
        nil

      [_, id, date, text] ->
        %{index: index, id: :binary.copy(id), date: :binary.copy(date), text: shown(text)}

      nil ->
        %{index: index, id: "#{index}", date: "", text: shown(line)}
    end
  end

  defp shown(text), do: text |> Shown.text() |> :binary.copy()
end
