defmodule MWTClient.Sandbox.HandoffStore do
  @moduledoc """
  Where a handoff's commits wait until you accept it: a bare git repository
  of MWT's own, one per project, in the identity's sandbox folder.

  Nothing of the VM's is written into your repository while it waits. The
  store borrows your repository's objects instead (git's alternates: its
  `objects/info/alternates` names your `.git/objects`), so a handoff brings
  only what is new, and git can work out its base, its diff and whether it
  merges, all here, from both histories at once. Your repository is only
  read.

  What MWT works out to show you (a merge, a snapshot of your working tree)
  runs in `view/2`: git writes what it makes into a folder of its own that
  is deleted after, not into the store and not into your repository.

  Handoffs sit under `refs/handoffs/<id>`.
  """

  alias MWTClient.Sandbox.{Guest, HostGit, Scratch, Secrets}
  alias MWTClient.Sandbox.Egress.Scanner

  @doc "The store for the repository whose top folder is `repo`, under the sandbox folder `dir`."
  @spec path(Path.t(), Path.t()) :: Path.t()
  def path(dir, repo) do
    hash = :crypto.hash(:sha256, repo) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Path.join([dir, "handoffs", "#{Path.basename(repo)}-#{hash}.git"])
  end

  @doc """
  Makes the store when there is none, and points it at the repository's
  objects (again, every time: the repository may have moved its own).
  """
  @spec ensure(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def ensure(store, repo) do
    with objects when is_binary(objects) <- objects(repo) || {:error, "That repository is gone."},
         :ok <- init(store) do
      File.write(Path.join([store, "objects", "info", "alternates"]), objects <> "\n")
    end
  end

  defp init(store) do
    if File.dir?(Path.join(store, "objects")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(store))

      case MWTClient.Executable.cmd("git", ["init", "--quiet", "--bare", store],
             env: Guest.git_env(),
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, _} -> {:error, String.trim(output)}
      end
    end
  end

  # The objects folder of the repository, shared by all its worktrees.
  defp objects(repo) do
    case HostGit.line(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      nil -> nil
      common -> Path.join(common, "objects")
    end
  end

  @doc """
  Fetches `branch` of the repository at `folder` in the VM into
  `refs/handoffs/<id>`, under a limit on what git may write (in MiB).
  Returns the commit that arrived.
  """
  @spec receive(Path.t(), Guest.t(), Path.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, :too_large | String.t()}
  def receive(store, guest, folder, branch, id, limit) do
    started = System.os_time(:second)

    source =
      if branch =~ ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/,
        do: branch,
        else: "refs/heads/" <> branch

    case HostGit.run(
           store,
           ["fetch", "--no-tags", "--no-write-fetch-head", guest.git_url.(folder)] ++
             ["+#{source}:#{ref(id)}"],
           env: guest.env,
           seconds: 600,
           file_limit: limit
         ) do
      {:ok, _} ->
        case HostGit.line(store, ["rev-parse", "--verify", "--quiet", ref(id)]) do
          nil -> {:error, "The branch did not arrive."}
          commit -> {:ok, commit}
        end

      {:error, text} ->
        # The kernel stops the write (SIGXFSZ, signal 25), and git says so
        # one way or the other.
        if text =~ ~r/died of signal 25|File too large|File size limit exceeded/i do
          sweep(store, started)
          {:error, :too_large}
        else
          {:error, text}
        end
    end
  end

  # What a fetch stopped halfway leaves: the files git was still writing.
  defp sweep(store, since) do
    objects = Path.join(store, "objects")

    for dir <- [objects | Enum.map(ls(objects), &Path.join(objects, &1))],
        name <- ls(dir),
        String.starts_with?(name, ["tmp_obj_", "tmp_pack_", "tmp_idx_", "tmp_rev_"]),
        path = Path.join(dir, name),
        {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime >= since,
        do: File.rm(path)

    :ok
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  @doc """
  Looks through everything a handoff brings, from `base` (nil: all of it)
  to `head`, for `secrets`: each commit, its message included, each folder
  listing and each file, as git keeps them. Returns nil, `{label, where}`
  for the first found, `where` in words (`"the file lib/x.ex"`), or
  `{:error, reason}`.

  Streams: `git cat-file --batch` is read a piece at a time, so a handoff
  of a GiB is never held whole.
  """
  @spec find(Path.t(), String.t(), String.t() | nil, Secrets.t() | nil) ::
          nil | {Secrets.label(), String.t()} | {:error, String.t()}
  def find(_store, _head, _base, nil), do: nil

  def find(store, head, base, secrets) do
    range = if base, do: [head, "--not", base], else: [head]

    case HostGit.run(store, ["rev-list", "--objects" | range],
           max: 256 * 1024 * 1024,
           seconds: 600
         ) do
      {:ok, listing} ->
        names =
          for line <- String.split(listing, "\n", trim: true), into: %{} do
            case String.split(line, " ", parts: 2) do
              [id, name] -> {id, name}
              [id] -> {id, nil}
            end
          end

        objects(store, Map.keys(names), names, secrets)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp objects(_store, [], _names, _secrets), do: nil

  defp objects(store, ids, names, secrets) do
    # The list goes in a folder only you can open (`Scratch`).
    Scratch.with_dir("mwt-objects", fn scratch ->
      list = Path.join(scratch, "objects")
      File.write!(list, Enum.map(ids, &[&1, "\n"]))

      port =
        Port.open({:spawn_executable, MWTClient.Executable.find("bash")}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["-c", ~s(exec git -C "$1" cat-file --batch < "$2"), "bash", store, list],
          env:
            Enum.map(Guest.git_env(), fn {k, v} ->
              {String.to_charlist(k), String.to_charlist(v)}
            end)
        ])

      batch(port, "", nil, names, secrets)
    end)
  end

  # `git cat-file --batch` says `<id> <type> <size>`, then the object, then
  # a line feed. `current` is the object being read: `{id, type, bytes
  # left, scanner}`, or `:line_feed` after one.
  defp batch(port, buffer, current, names, secrets) do
    case read_batch(buffer, current, names, secrets) do
      {:more, buffer, current} ->
        receive do
          {^port, {:data, data}} -> batch(port, buffer <> data, current, names, secrets)
          {^port, {:exit_status, 0}} -> nil
          {^port, {:exit_status, status}} -> {:error, "git cat-file exited with #{status}"}
        after
          60_000 ->
            stop(port)
            {:error, "git cat-file stopped answering"}
        end

      {:found, label, where} ->
        stop(port)
        {label, where}
    end
  end

  # Closed, unless git ended first, and nothing of it left in the mailbox.
  defp stop(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  after
    drain(port)
  end

  defp drain(port) do
    receive do
      {^port, _message} -> drain(port)
    after
      0 -> :ok
    end
  end

  defp read_batch(buffer, nil, names, secrets) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        case String.split(line, " ") do
          [id, type, size] ->
            current = {id, type, String.to_integer(size), Scanner.new(secrets)}
            read_batch(rest, current, names, secrets)

          [_id, "missing"] ->
            read_batch(rest, nil, names, secrets)
        end

      [_partial] ->
        {:more, buffer, nil}
    end
  end

  defp read_batch(buffer, :line_feed, names, secrets) do
    case buffer do
      "\n" <> rest -> read_batch(rest, nil, names, secrets)
      "" -> {:more, "", :line_feed}
    end
  end

  defp read_batch(buffer, {id, type, left, scanner}, names, secrets) do
    take = min(left, byte_size(buffer))
    <<part::binary-size(take), rest::binary>> = buffer

    case Scanner.feed(scanner, part) do
      {:found, label} ->
        {:found, label, where(type, id, names[id])}

      {:ok, _part, _scanner} when take == left ->
        read_batch(rest, :line_feed, names, secrets)

      {:ok, _part, scanner} ->
        {:more, rest, {id, type, left - take, scanner}}
    end
  end

  defp where("commit", id, _name), do: "commit #{binary_part(id, 0, 10)}"
  defp where("blob", _id, name) when name not in [nil, ""], do: "the file #{name}"
  defp where("tree", _id, name) when name not in [nil, ""], do: "the folder listing of #{name}"
  defp where(type, id, _name), do: "#{type} #{binary_part(id, 0, 10)}"

  @doc "The ref a handoff's commit sits at in the store."
  @spec ref(pos_integer()) :: String.t()
  def ref(id), do: "refs/handoffs/#{id}"

  @doc "Puts a handoff's ref back on `commit`, as when a new revision is refused."
  @spec point(Path.t(), pos_integer(), String.t()) :: :ok
  def point(store, id, commit) do
    HostGit.run(store, ["update-ref", ref(id), commit])
    :ok
  end

  @doc "Lets go of a handoff's commit."
  @spec drop(Path.t(), pos_integer()) :: :ok
  def drop(store, id) do
    if File.dir?(store), do: HostGit.run(store, ["update-ref", "-d", ref(id)])
    :ok
  end

  @doc """
  Runs `fun` with the environment in which git, run in the store or in
  your repository, sees both histories and writes what it makes into a
  folder of its own, deleted when `fun` returns.
  """
  @spec view(Path.t(), ([{String.t(), String.t()}] -> result)) :: result when result: var
  def view(store, fun) do
    # A folder only you can open: objects git reads from it are its own.
    Scratch.with_dir("mwt-view", fn scratch ->
      fun.([
        {"GIT_OBJECT_DIRECTORY", scratch},
        # The store's own alternates lead on to your repository's objects.
        {"GIT_ALTERNATE_OBJECT_DIRECTORIES", Path.join(store, "objects")}
      ])
    end)
  end

  @doc "Keeps each submitted revision reachable independently of its moving branch."
  def keep_revision(store, id, revision, head) do
    target = "refs/handoff-revisions/#{id}/#{revision}"

    case HostGit.line(store, ["rev-parse", "--verify", "--quiet", target]) do
      ^head ->
        :ok

      nil ->
        case HostGit.run(store, [
               "update-ref",
               target,
               head,
               String.duplicate("0", byte_size(head))
             ]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, "That handoff revision already names another commit."}
    end
  end

  @doc """
  Brings a handoff's commits into your repository, at
  `refs/mwt/handoffs/<id>`, a ref no tool lists as a branch. Done only when
  you accept it.
  """
  @spec copy_into(Path.t(), Path.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def copy_into(store, repo, id, head \\ nil) do
    target = "refs/mwt/handoffs/#{id}"
    source = head || ref(id)

    with {:ok, _} <-
           HostGit.run(
             repo,
             ["fetch", "--no-tags", "--no-write-fetch-head", store, "+#{source}:#{target}"],
             seconds: 600
           ),
         commit when is_binary(commit) <- HostGit.line(repo, ["rev-parse", "--verify", target]) do
      {:ok, commit}
    else
      nil -> {:error, "The handoff's commits did not arrive in your repository."}
      {:error, reason} -> {:error, reason}
    end
  end
end
