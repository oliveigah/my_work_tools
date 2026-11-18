defmodule MWTClient.Sandbox.FolderSync do
  @moduledoc """
  Folders of this machine, copied into the VM: one way, from here to the
  VM's own storage. Nothing of them is mounted, so live sharing needs no
  coherence from microsandbox. Two kinds of copy use it:

    * `:share` - a shared folder of yours, at the same path. A git working
      tree in it (a folder holding `.git`, a folder or a file) is never
      copied: it reaches the VM as a project, by git
      (`MWTClient.Sandbox.Mirror`), so what a repository keeps beside its
      code (`.env`, ignored secrets, `.git` itself) stays on your machine.
      Its path in the VM is left alone, including anything already there.
      What the VM changed in the rest of its copy is set aside, never lost.
    * `:mwt` - a folder of MWT's own, such as `/mnt/mwt`
      (`MWTClient.Sandbox.Inbox`): copied whole, and what the VM changed in
      it is simply replaced.

  Everything else is copied: files, folders, and symlinks as links, never
  followed. One look at a folder (`sync/4`):

    1. **Scan** it here, with `lstat` only, and compare it with what MWT
       last sent to this VM (`sent`): kind, size and modification time to
       the second, a link's target. A file changed in the last 2 s is sent
       again until it settles; one whose change time or inode moved since
       the last scan is sent even when its size and time agree.
    2. **Compare the whole copy** with what the VM really has (`find
       -printf` there) at the first look after a start, after a failure,
       and every 5 minutes; in between, what MWT sent is what the VM has.
    3. **Clear the way** (a bash script in the VM): for each path about to
       be replaced or removed, what MWT expects there (what it sent) is
       compared with what is there. For a share, anything else (the VM's
       own change) is moved to `/work/.rescued/TIME/PATH` first. Then what
       you deleted is removed.
    4. **Send** the changed files: `tar` here into `tar -x` there, through
       `msb exec --stream`, into `.mwt-incoming` beside them, then each is
       renamed into place. A program in the VM sees a file whole, the old
       one or the new, never half written.

  `copy/3` is steps 1 and 4 alone, for a folder sent once into an empty
  place (your memory, `MWTClient.Sandbox.Memory`).

  MWT reads from the VM only that file list, at most 64 MiB and 400,000
  entries of it, a count of what was set aside, and the first 64 KiB of
  any errors; nothing it sends is run here. What was sent
  is kept per VM in `~/.mwt_client/<id>/sandbox/sync/`, so after a restart
  of MWT a change the VM made is still told from yours.

  The guest map (`MWTClient.Sandbox.Guest`) gives `exec`, `stream` (the
  words that run a command in the VM with its input and output streamed)
  and `place` (where a path of the VM is for this machine), so tests copy
  into a folder of this machine.
  """

  alias MWTClient.Sandbox.{Bounded, Scratch, Shown}

  @max_entries 200_000
  @max_bytes 4 * 1024 * 1024 * 1024
  @settle_seconds 2
  @recheck_ms 5 * 60 * 1_000
  @seconds 600
  @max_list 64 * 1024 * 1024
  # The VM's copy may hold more than the folder (what it added itself),
  # but not without end: its list is parsed into memory.
  @max_listed 2 * @max_entries
  # What MWT takes of a step's errors, and shows of them.
  @error_bytes 64 * 1024
  @error_shown 2 * 1024
  # Where a send lands in the VM before each file is renamed into place,
  # inside the copy so the rename stays on one file system. Never copied.
  @stage ".mwt-incoming"

  @typedoc "One path of a folder: a file, a folder or a symlink."
  @type entry :: {:file, non_neg_integer(), integer()} | {:link, binary()} | :dir | :unknown

  @typedoc "Whose folder a copy is: yours (`:share`), or MWT's own (`:mwt`)."
  @type kind :: :share | :mwt

  @typedoc """
  What MWT knows of one folder's copy in one VM: the folder here (`path`),
  where the copy is in the VM (`to`) and its kind.
  """
  @type record :: %{
          path: Path.t(),
          to: Path.t(),
          kind: kind(),
          vm: String.t(),
          sent: %{binary() => entry()} | nil,
          stamps: %{binary() => {integer(), integer()}},
          checked_at: integer() | nil,
          status: status()
        }

  @typedoc "What the pages show of a record."
  @type status :: %{
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          trees: [binary()],
          project?: boolean(),
          synced_at: DateTime.t() | nil,
          changed_at: DateTime.t() | nil,
          error: String.t() | nil,
          rescued: non_neg_integer(),
          rescued_to: String.t() | nil
        }

  # The VM's side, step 2: every path of the copy, with its kind, size,
  # modification time and link target, but a send under way. Its folder is
  # made when missing.
  @list """
  set -e
  mkdir -p -- "$1"
  cd -- "$1"
  find . -mindepth 1 -path ./#{@stage} -prune -o -printf '%y\\0%s\\0%T@\\0%l\\0%P\\0' 2>/dev/null
  """

  # The VM's side, step 3. Each record, NUL-separated: the action (del, or
  # put-f, put-l, put-d for what comes next), the path, and what MWT
  # expects there: kind (f, l, d, - for nothing, ? for anything), size,
  # modification time and link target. With no rescue folder (a copy of
  # MWT's own), what isn't as expected is removed instead of set aside. A
  # file or link about to be replaced by one stays: the send renames over
  # it. Prints how many paths it set aside.
  @prepare ~S"""
  set -u
  root=$1 rescue=$2 moved=0
  mkdir -p -- "$root"
  aside() {
    if [ -z "$rescue" ]; then rm -rf -- "$root/$1"; return; fi
    mkdir -p -- "$rescue/$(dirname -- "$1")"
    mv -- "$root/$1" "$rescue/$1" && moved=$((moved + 1))
  }
  while IFS= read -r -d '' action && IFS= read -r -d '' path && IFS= read -r -d '' kind &&
    IFS= read -r -d '' size && IFS= read -r -d '' mtime && IFS= read -r -d '' target; do
    p=$root/$path
    if [ -L "$p" ]; then now=l
    elif [ -d "$p" ]; then now=d
    elif [ -f "$p" ]; then now=f
    elif [ -e "$p" ]; then now=o
    else continue
    fi
    same=0
    if [ "$kind" = "?" ]; then same=1
    elif [ "$now" = "$kind" ]; then
      case $now in
        f) [ "$(stat -c '%s %Y' -- "$p")" = "$size $mtime" ] && same=1 ;;
        l) [ "$(readlink -- "$p")" = "$target" ] && same=1 ;;
        d) same=1 ;;
      esac
    fi
    if [ "$same" = 0 ]; then aside "$path"; continue; fi
    case $action:$now in
      put-d:d | put-[fl]:[fl]) ;;
      *:d) rmdir -- "$p" 2>/dev/null || aside "$path" ;;
      *) rm -f -- "$p" ;;
    esac
  done
  echo "$moved"
  """

  # The VM's side, step 4: the tar stream on its input, unpacked into the
  # staging folder, then moved into place: folders first (made when
  # missing, with the mode sent), then every file and link, each with one
  # rename, which replaces what is there whole.
  @receive ~S"""
  set -euo pipefail
  root=$1 stage=$1/$2
  mkdir -p -- "$root"
  rm -rf -- "$stage"
  mkdir -- "$stage"
  tar -x -f - -C "$stage" --no-same-owner
  cd -- "$stage"
  mapfile -d '' dirs < <(find . -mindepth 1 -type d -printf '%P\0')
  mapfile -d '' rest < <(find . -mindepth 1 ! -type d -printf '%P\0')
  for d in "${dirs[@]}"; do
    if [ ! -d "$root/$d" ]; then
      mkdir -- "$root/$d"
      chmod --reference="$d" -- "$root/$d"
    fi
  done
  for f in "${rest[@]}"; do mv -fT -- "$f" "$root/$f"; done
  cd /
  rm -rf -- "$stage"
  """

  # This machine's side, step 4: the files named in a list, sent as a tar
  # stream into the command that follows. tar ends with 1 when a file
  # changed while it read it: what it sent shows as changed next time.
  @send ~S"""
  set -u
  share=$1 list=$2
  shift 2
  tar -C "$share" --null --verbatim-files-from --no-recursion --hard-dereference \
    --format=gnu -c -f - -T "$list" 2>"$MWT_ERRORS" | "$@"
  status=("${PIPESTATUS[@]}")
  [ "${status[0]}" -le 1 ] && [ "${status[1]}" -eq 0 ]
  """

  @doc """
  A record for a folder MWT hasn't looked at for this VM yet: a shared
  folder, at the same path in the VM, unless `opts` say otherwise (`to:`,
  `kind:`).
  """
  @spec new(Path.t(), String.t(), keyword()) :: record()
  def new(path, vm, opts \\ []) do
    %{
      path: path,
      to: Keyword.get(opts, :to, path),
      kind: Keyword.get(opts, :kind, :share),
      vm: vm,
      sent: nil,
      stamps: %{},
      checked_at: nil,
      status: %{
        files: 0,
        bytes: 0,
        trees: [],
        project?: false,
        synced_at: nil,
        changed_at: nil,
        error: nil,
        rescued: 0,
        rescued_to: nil
      }
    }
  end

  @doc """
  One look at the folder of `record`: brings its copy in the VM behind
  `guest` up to date. `dir` holds what was sent, per folder and VM.
  Returns the record as it is after the look; an error is in its status.

  With `fresh: true`, the copy's place in the VM is known to be empty (a
  folder in memory just made at a start): everything is sent with a plain
  `tar -x`, which needs neither bash nor GNU tools there.
  """
  @spec sync(record(), map(), Path.t(), keyword()) :: record()
  def sync(record, guest, dir, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
    clock = Keyword.get_lazy(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    fresh? = Keyword.get(opts, :fresh, false)
    record = with_sent(record, dir)

    case scan(record.path, now, record.kind) do
      {:ok, %{project?: true} = scan} ->
        status = %{record.status | project?: true, trees: scan.trees, files: 0, bytes: 0}
        %{record | status: %{status | error: nil, synced_at: DateTime.utc_now()}}

      {:ok, scan} ->
        record
        |> bring(scan, guest, dir, clock, fresh?)
        |> then(fn record ->
          %{
            record
            | stamps: scan.stamps,
              status: %{record.status | trees: scan.trees, project?: false}
          }
        end)

      {:error, reason} ->
        put_in(record.status.error, explain(reason))
    end
  end

  # What was sent: from memory, else from the file kept for this VM, else
  # nothing, and then the whole copy is compared at once.
  defp with_sent(%{sent: sent} = record, _dir) when is_map(sent), do: record

  defp with_sent(record, dir) do
    case File.read(sent_file(dir, record.path)) do
      {:ok, bytes} ->
        case :erlang.binary_to_term(bytes, [:safe]) do
          %{vm: vm, sent: sent} when vm == record.vm and is_map(sent) ->
            %{record | sent: sent, checked_at: nil}

          _other ->
            %{record | sent: %{}, checked_at: nil}
        end

      {:error, _} ->
        %{record | sent: %{}, checked_at: nil}
    end
  rescue
    ArgumentError -> %{record | sent: %{}, checked_at: nil}
  end

  defp sent_file(dir, path) do
    hash = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    Path.join([dir, "sync", hash <> ".bin"])
  end

  defp bring(record, scan, guest, dir, clock, fresh?) do
    place = guest.place.(record.to)
    have = if fresh?, do: {:ok, %{}, clock}, else: have(record, guest, place, clock)

    with {:ok, have, checked_at} <- have do
      # Excluded working trees aren't deletions. Their paths in the VM
      # stay outside this copy, even if they were sent before becoming a
      # repository or were already there at the first look.
      have =
        Map.reject(have, fn {path, _entry} ->
          Enum.any?(scan.trees, &(path == &1 or String.starts_with?(path, &1 <> "/")))
        end)

      %{send: changed, remove: remove} = plan(scan, record.sent, have, record.stamps)

      if changed == [] and remove == [] do
        # A copy just compared whole is what MWT sent from now on.
        if have != record.sent, do: write_sent(dir, record, have)
        done(record, scan, have, checked_at, 0, nil, false)
      else
        rescue_dir = rescue_dir(guest, record)
        expect = record.sent

        prepared =
          if fresh?,
            do: {:ok, 0},
            else: prepare(guest, place, rescue_dir, changed, remove, scan, expect)

        with {:ok, moved} <- prepared,
             :ok <- transfer(guest, record.path, place, changed, fresh?) do
          sent = after_send(record.path, scan, changed, remove, have)
          write_sent(dir, record, sent)
          done(record, scan, sent, checked_at, moved, moved > 0 && rescue_dir, true)
        else
          {:error, message} ->
            # What the VM holds is unsure now: compared whole next time,
            # and nothing being sent is taken for the VM's own change.
            sent = Enum.reduce(changed, record.sent, &Map.put(&2, &1, :unknown))
            %{record | sent: sent, checked_at: nil, status: %{record.status | error: message}}
        end
      end
    else
      {:error, message} ->
        %{record | checked_at: nil, status: %{record.status | error: message}}
    end
  end

  # What the VM's copy holds: what was sent, unless it is time to look.
  defp have(record, guest, place, clock) do
    if record.checked_at != nil and clock - record.checked_at < @recheck_ms do
      {:ok, record.sent, record.checked_at}
    else
      case read(guest, ["bash", "-c", @list, "mwt-sync", place], @max_list) do
        {:ok, output} ->
          case parse_list(output) do
            {:ok, have} ->
              {:ok, have, clock}

            {:error, :too_many} ->
              {:error,
               "The VM's copy couldn't be read: it holds more than #{@max_listed} files and folders"}
          end

        {:error, text} ->
          {:error, "The VM's copy couldn't be read: " <> text}
      end
    end
  end

  @doc """
  What to send and what to remove so the copy holding `have` becomes the
  folder as `scan` found it. `sent` and `stamps` are what MWT sent and the
  last scan's change times, to catch a change that kept size and time.
  """
  @spec plan(map(), map(), map(), map()) :: %{send: [binary()], remove: [binary()]}
  def plan(scan, sent, have, stamps) do
    send =
      for {path, entry} <- scan.entries,
          Map.get(have, path) != entry or Map.get(sent, path) == :unknown or
            MapSet.member?(scan.unsettled, path) or
            (Map.has_key?(stamps, path) and stamps[path] != scan.stamps[path]),
          do: path

    remove = for {path, _entry} <- have, not Map.has_key?(scan.entries, path), do: path
    %{send: Enum.sort(send), remove: remove}
  end

  # Where the VM's own changes to a share go; a copy of MWT's own has none.
  defp rescue_dir(_guest, %{kind: :mwt}), do: ""

  defp rescue_dir(guest, record) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    Path.join([guest.root, ".rescued", stamp]) <> record.to
  end

  defp prepare(guest, place, rescue_dir, send, remove, scan, expect) do
    # Files and links first, then folders, deepest first, so a folder is
    # empty by the time it is removed; then what comes in.
    {dirs, others} = Enum.split_with(remove, &(Map.get(expect, &1) == :dir))
    dirs = Enum.sort_by(dirs, &(-depth(&1)))

    records =
      Enum.map(others ++ dirs, &record_line("del", &1, Map.get(expect, &1))) ++
        Enum.map(send, &record_line(put(scan.entries[&1]), &1, Map.get(expect, &1)))

    with_file(records, fn input ->
      words = guest.stream.(["bash", "-c", @prepare, "mwt-sync", place, rescue_dir])

      case run(["-c", ~s("$@" < "$MWT_INPUT"), "bash" | words], [{"MWT_INPUT", input}], guest) do
        {:ok, output} ->
          case Integer.parse(String.trim(output)) do
            {moved, ""} -> {:ok, moved}
            _ -> {:error, "The VM's copy couldn't be prepared: " <> error_text(output)}
          end

        {:error, text} ->
          {:error, "The VM's copy couldn't be prepared: " <> text}
      end
    end)
  end

  defp put({:file, _, _}), do: "put-f"
  defp put({:link, _}), do: "put-l"
  defp put(:dir), do: "put-d"

  defp record_line(action, path, expected) do
    {kind, size, mtime, target} =
      case expected do
        nil -> {"-", "", "", ""}
        :unknown -> {"?", "", "", ""}
        :dir -> {"d", "", "", ""}
        {:link, target} -> {"l", "", "", target}
        {:file, size, mtime} -> {"f", "#{size}", "#{mtime}", ""}
      end

    Enum.map([action, path, kind, size, mtime, target], &[&1, 0])
  end

  defp transfer(guest, share, place, paths, fresh? \\ false)

  defp transfer(_guest, _share, _place, [], _fresh?), do: :ok

  defp transfer(guest, share, place, paths, fresh?) do
    list = Enum.map(paths, &["./", &1, 0])

    # Into an empty place, nothing is there to replace: tar alone, which
    # busybox's does too (`-o`: owned by whoever unpacks, as GNU's).
    words =
      if fresh?,
        do: ["sh", "-c", ~s(mkdir -p -- "$1" && tar -x -o -f - -C "$1"), "mwt-sync", place],
        else: ["bash", "-c", @receive, "mwt-sync", place, @stage]

    # The host's tar writes its own errors beside the list, in MWT's own
    # folder.
    with_file(list, fn file ->
      errors = file <> ".errors"
      words = guest.stream.(words)

      case run(["-c", @send, "mwt-sync", share, file | words], [{"MWT_ERRORS", errors}], guest) do
        {:ok, _output} ->
          :ok

        {:error, text} ->
          detail = errors |> head_of() |> String.trim() |> error_text()
          {:error, "The files couldn't be sent: " <> Enum.join([detail, text], " ")}
      end
    end)
  end

  @doc """
  Runs `words` in the VM behind `guest` and returns what it printed: data
  the VM writes, so at most `max` bytes of it are taken, and more is an
  error, the command stopped (`MWTClient.Sandbox.Bounded`). Its errors are
  the VM's too, apart from the data: the start of them is the error
  returned. The pull from the VM to this machine.
  """
  @spec read(map(), [String.t()], pos_integer()) :: {:ok, binary()} | {:error, String.t()}
  def read(guest, words, max) do
    [command | args] = guest.stream.(words)

    case Bounded.cmd(command, args, max: max, seconds: @seconds, env: guest.env) do
      {:ok, output, _errors, 0} -> {:ok, output}
      {:ok, _output, errors, _status} -> {:error, errors |> String.trim() |> error_text()}
      {:error, {:too_long, _head}} -> {:error, "it is more than #{max} bytes"}
      {:error, :timeout} -> {:error, "it took longer than #{@seconds} s"}
    end
  end

  @doc """
  Sends the folder `source` whole into `to` in the VM behind `guest`, a
  place that holds nothing yet: steps 1 and 4 of a look, for a folder sent
  once. Nothing is recorded.
  """
  @spec copy(Path.t(), map(), Path.t()) :: :ok | {:error, String.t()}
  def copy(source, guest, to) do
    case scan(source, System.os_time(:second), :mwt) do
      {:ok, scan} -> transfer(guest, source, guest.place.(to), Enum.sort(Map.keys(scan.entries)))
      {:error, reason} -> {:error, explain(reason)}
    end
  end

  # A step whose output is a count or nothing: at most `@error_bytes` of it
  # are taken. Its errors are apart, so a warning in the VM doesn't spoil
  # the count.
  defp run(args, env, guest) do
    case Bounded.cmd("bash", args, max: @error_bytes, seconds: @seconds, env: env ++ guest.env) do
      {:ok, output, _errors, 0} ->
        {:ok, output}

      {:ok, output, errors, _status} ->
        {:error, output |> Bounded.failure(errors, @error_bytes) |> error_text()}

      {:error, {:too_long, head}} ->
        {:error, "it printed more than 64 KiB: " <> error_text(head)}

      {:error, :timeout} ->
        {:error, "it took longer than #{@seconds} s"}
    end
  end

  # Text from the VM, or from tar here about files in it, as a status's
  # error: made to show all it holds, and short enough for a page.
  defp error_text(text), do: text |> Shown.text() |> Bounded.brief(@error_shown)

  # The start of a file of errors: what wrote it is done, but its length
  # is not MWT's to decide.
  defp head_of(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, @error_bytes) do
            data when is_binary(data) -> data
            _eof_or_error -> ""
          end
        after
          File.close(file)
        end

      {:error, _reason} ->
        ""
    end
  end

  # A file holding `iodata`, in a folder only MWT's user can open: what a
  # command reads from it is what MWT wrote.
  defp with_file(iodata, fun) do
    Scratch.with_dir("mwt-sync", fn dir ->
      path = Path.join(dir, "list")
      File.write!(path, iodata)
      fun.(path)
    end)
  end

  # What the copy holds after a send: the folder as scanned, except a file
  # that changed again while it was sent, which counts as unknown.
  defp after_send(share, scan, send, remove, have) do
    sent = Map.drop(have, remove) |> Map.merge(Map.take(scan.entries, send))

    Enum.reduce(send, sent, fn path, sent ->
      if entry(Path.join(share, path)) == scan.entries[path],
        do: sent,
        else: Map.put(sent, path, :unknown)
    end)
  end

  defp write_sent(dir, record, sent) do
    path = sent_file(dir, record.path)
    File.mkdir_p!(Path.dirname(path))
    temporary = "#{path}.#{System.unique_integer([:positive])}"

    File.write!(
      temporary,
      :erlang.term_to_binary(%{vm: record.vm, path: record.path, sent: sent}, [:compressed])
    )

    File.rename!(temporary, path)
  end

  defp done(record, scan, sent, checked_at, moved, rescued_to, changed?) do
    now = DateTime.utc_now()

    status = %{
      record.status
      | files: scan.files,
        bytes: scan.bytes,
        synced_at: now,
        changed_at: if(changed?, do: now, else: record.status.changed_at),
        error: nil,
        rescued: record.status.rescued + moved,
        rescued_to: rescued_to || record.status.rescued_to
    }

    %{record | sent: sent, checked_at: checked_at, status: status}
  end

  @doc """
  The VM's file list as `@list` prints it, as entries by path. A record
  that isn't a plain relative path is left out. The list is the VM's: at
  most `most` records are read, and a list holding more is
  `{:error, :too_many}`. What is kept is copied out of `output`, so the
  list itself isn't held with it.
  """
  @spec parse_list(binary(), pos_integer()) :: {:ok, %{binary() => entry()}} | {:error, :too_many}
  def parse_list(output, most \\ @max_listed), do: parse_records(output, 0, most, %{})

  defp parse_records(output, at, left, have) do
    case fields(output, at, 5, []) do
      :done ->
        {:ok, have}

      {_record, _next} when left == 0 ->
        {:error, :too_many}

      {[kind, size, mtime, target, path], next} ->
        have =
          if relative?(path),
            do: Map.put(have, :binary.copy(path), listed(kind, size, mtime, target)),
            else: have

        parse_records(output, next, left - 1, have)
    end
  end

  # The next `count` fields from `at`, each ended by a NUL, or `:done` when
  # fewer are left.
  defp fields(_output, at, 0, acc), do: {Enum.reverse(acc), at}

  defp fields(output, at, count, acc) do
    case :binary.match(output, <<0>>, scope: {at, byte_size(output) - at}) do
      {nul, 1} -> fields(output, nul + 1, count - 1, [binary_part(output, at, nul - at) | acc])
      :nomatch -> :done
    end
  end

  defp listed("f", size, mtime, _target) do
    with {size, ""} <- Integer.parse(size),
         {seconds, _fraction} <- Integer.parse(mtime) do
      {:file, size, seconds}
    else
      _ -> :unknown
    end
  end

  defp listed("d", _size, _mtime, _target), do: :dir
  defp listed("l", _size, _mtime, target), do: {:link, :binary.copy(target)}
  defp listed(_other, _size, _mtime, _target), do: :unknown

  defp relative?(path) do
    path != "" and
      Enum.all?(:binary.split(path, "/", [:global]), &(&1 not in ["", ".", ".."]))
  end

  defp depth(path), do: length(:binary.split(path, "/", [:global]))

  @doc """
  The folder at `root` as this machine has it: its entries by relative
  path (working trees left out), the change times and inodes of its files,
  the files changed in the last 2 s before `now`, and the working trees it
  holds. For a share, `project?` when `root` is one itself, and an error
  when it is inside one; a folder of MWT's own is never either.
  """
  @spec scan(Path.t(), integer(), kind()) :: {:ok, map()} | {:error, term()}
  def scan(root, now, kind \\ :share) do
    cond do
      not File.dir?(root) ->
        {:error, :missing}

      kind == :share and git_entry?(root) ->
        {:ok, %{project?: true, trees: [""]}}

      inside = kind == :share && enclosing(Path.dirname(root)) ->
        {:error, {:inside, inside}}

      true ->
        acc = %{
          kind: kind,
          project?: false,
          entries: %{},
          stamps: %{},
          unsettled: MapSet.new(),
          trees: [],
          files: 0,
          bytes: 0,
          count: 0
        }

        with {:ok, acc} <- walk([{"", root}], acc, now) do
          {:ok, acc |> Map.delete(:kind) |> Map.update!(:trees, &Enum.sort/1)}
        end
    end
  end

  defp walk([], acc, _now), do: {:ok, acc}

  defp walk([{rel, abs} | rest], acc, now) do
    case :file.list_dir_all(abs) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, rest, acc}, fn name, {:ok, queue, acc} ->
          # A name in the system's encoding comes as characters, any other
          # as its raw bytes.
          name = if is_list(name), do: List.to_string(name), else: name
          child_rel = if rel == "", do: name, else: rel <> "/" <> name
          child = Path.join(abs, name)

          # The name a send stages under in the VM is never copied.
          if child_rel == @stage do
            {:cont, {:ok, queue, acc}}
          else
            case add(acc, child_rel, child, now) do
              {:dir, acc} -> {:cont, {:ok, [{child_rel, child} | queue], acc}}
              {:ok, acc} -> {:cont, {:ok, queue, acc}}
              {:error, _} = error -> {:halt, error}
            end
          end
        end)
        |> case do
          {:ok, queue, acc} -> walk(queue, acc, now)
          error -> error
        end

      {:error, _} ->
        # A folder that can't be read is left as it is: empty in the copy.
        walk(rest, acc, now)
    end
  end

  defp add(acc, rel, abs, now) do
    case File.lstat(abs, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        if acc.kind == :share and git_entry?(abs),
          do: {:ok, %{acc | trees: [rel | acc.trees]}},
          else: counted(%{acc | entries: Map.put(acc.entries, rel, :dir)}, :dir)

      {:ok, %File.Stat{type: :regular} = stat} ->
        acc = %{
          acc
          | entries: Map.put(acc.entries, rel, {:file, stat.size, stat.mtime}),
            stamps: Map.put(acc.stamps, rel, {stat.ctime, stat.inode}),
            unsettled:
              if(stat.mtime >= now - @settle_seconds or stat.ctime >= now - @settle_seconds,
                do: MapSet.put(acc.unsettled, rel),
                else: acc.unsettled
              ),
            files: acc.files + 1,
            bytes: acc.bytes + stat.size
        }

        counted(acc, :ok)

      {:ok, %File.Stat{type: :symlink}} ->
        case :file.read_link_all(abs) do
          {:ok, target} when is_binary(target) ->
            counted(%{acc | entries: Map.put(acc.entries, rel, {:link, target})}, :ok)

          {:ok, target} ->
            entry = {:link, IO.chardata_to_string(target)}
            counted(%{acc | entries: Map.put(acc.entries, rel, entry)}, :ok)

          {:error, _} ->
            {:ok, acc}
        end

      # Devices, sockets, pipes, and what vanished or can't be read.
      _other ->
        {:ok, acc}
    end
  end

  defp counted(acc, result) do
    acc = %{acc | count: acc.count + 1}

    cond do
      acc.count > @max_entries -> {:error, {:too_big, :entries}}
      acc.bytes > @max_bytes -> {:error, {:too_big, :bytes}}
      true -> {result, acc}
    end
  end

  # What a path is now, as `scan/2` records it.
  defp entry(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} -> {:file, size, mtime}
      {:ok, %File.Stat{type: :directory}} -> :dir
      {:ok, %File.Stat{type: :symlink}} -> link(path)
      _ -> :unknown
    end
  end

  defp link(path) do
    case :file.read_link_all(path) do
      {:ok, target} -> {:link, IO.chardata_to_string(target)}
      _ -> :unknown
    end
  end

  @doc """
  The git working tree holding `path`, the folder itself or one above it:
  the nearest folder with `.git`, as git looks for it. Nil when none.
  """
  @spec enclosing(Path.t()) :: Path.t() | nil
  def enclosing(path) do
    cond do
      git_entry?(path) -> path
      path == "/" -> nil
      true -> enclosing(Path.dirname(path))
    end
  end

  defp git_entry?(dir), do: match?({:ok, _}, File.lstat(Path.join(dir, ".git")))

  @doc """
  One look at every folder in `records` (by path), one after the other,
  for the sandbox server's task. Returns the records after it and
  how long it took, in milliseconds.
  """
  @spec sync_all(%{Path.t() => record()}, map(), Path.t()) :: %{
          records: %{Path.t() => record()},
          took: non_neg_integer()
        }
  def sync_all(records, guest, dir) do
    started = System.monotonic_time(:millisecond)

    records =
      Map.new(records, fn {path, record} ->
        try do
          {path, sync(record, guest, dir)}
        rescue
          error -> {path, put_in(record.status.error, Exception.message(error))}
        end
      end)

    %{records: records, took: System.monotonic_time(:millisecond) - started}
  end

  @doc "What the pages compare to tell whether a record changed: its status but the time of the last look."
  @spec shown(record()) :: map()
  def shown(record), do: Map.delete(record.status, :synced_at)

  @doc "Why a folder couldn't be copied, in words."
  @spec explain(term()) :: String.t()
  def explain(:missing), do: "The folder isn't there."

  def explain({:inside, root}),
    do:
      "It is inside the git working tree #{root}, so nothing of it is copied: it would carry what that repository ignores. Share the repository instead."

  def explain({:too_big, :entries}),
    do:
      "It holds more than #{@max_entries} files and folders, so nothing more is copied. Share a smaller folder."

  def explain({:too_big, :bytes}),
    do:
      "It holds more than #{div(@max_bytes, 1024 * 1024 * 1024)} GiB, so nothing more is copied. Share a smaller folder."
end
