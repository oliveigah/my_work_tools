defmodule MWTClient.Sandbox.Pins do
  @moduledoc """
  The files a command on your machine runs, pinned: what you approve is
  each file as it was when you looked, not whatever it holds when it runs.

  A command's text shows what it runs, but not what a file it runs holds
  (`./deploy.sh`), and that file may change between your look and the run:
  a pull, an edit, or an earlier command the agent wrote. So:

    * a card (a command the agent wrote, or a saved command's run) shows
      each file's content and keeps its hash (`of/3`); just before the
      command runs, MWT hashes the file again, and one changed or gone
      runs nothing (`changed/1`);
    * a saved command keeps them as it is saved; a run whose files changed
      since asks, whatever its setting (`moved/2`), its card showing the
      difference (`diff/2`), and running it pins what is there now.

  Which files: those `MWTClient.Sandbox.ScriptRuns` reads the text runs,
  each resolved in the folder the command is in at that point (after its
  `cd`s), with the workspace and the home the command runs with put in
  for `$MWT_WORKSPACE`, `$HOME` and `~`.

  A file it can't tell (a path holding any other variable, a `cd` it
  can't follow, shell code built from a variable, code piped in) is a
  pin of its own, with no path and why (`why`): the card says MWT can't
  show it or pin it, and a saved command's run with one asks each time
  (`moved/2`), since nothing says it is what you saw. A card of a command
  the agent wrote asks anyway, and runs it once you let it, said so.

  Not pinned, and said so on the card: what a file runs in turn, a file
  it only reads, and a change in the instant between the check and the
  shell opening the file. It catches what happens between your look and
  the run, minutes or weeks apart; not a race designed against it.
  """

  alias MWTClient.Sandbox.ScriptRuns

  # What a card shows of each file; its hash is of all of it.
  @shown 16 * 1024

  @typedoc """
  One file: as the command names it, from the folder it starts in
  (`file`), where that is (`path`, nil when MWT can't tell, and `why`,
  said to complete "Runs FILE, …"), whether the VM wrote it (`vm?`, in
  the workspace's `from-vm/`), and what it holds: its `hash` and `size`,
  and the start of its `content`; `hash` nil when it isn't there or
  can't be read. Pins saved before `why` have none.
  """
  @type pin :: %{
          file: String.t(),
          path: String.t() | nil,
          why: String.t() | nil,
          vm?: boolean(),
          hash: String.t() | nil,
          size: non_neg_integer(),
          content: String.t()
        }

  @doc """
  The files `script` runs in `dir`, each as it is now. `workspace` is the
  workspace's folder on this machine, or nil.
  """
  @spec of(String.t(), String.t(), String.t() | nil) :: [pin()]
  def of(script, dir, workspace) do
    vars =
      if is_binary(workspace),
        do: %{"HOME" => home(), "MWT_WORKSPACE" => workspace},
        else: %{"HOME" => home()}

    script
    |> ScriptRuns.files()
    |> Enum.map(&pin(&1, dir, workspace, vars))
    |> Enum.uniq_by(&(&1.path || {&1.file, &1.why}))
  end

  defp pin({:unread, shown, why}, _dir, _workspace, _vars), do: unknown(shown, why)

  defp pin({:file, shown, word, folder}, dir, workspace, vars) do
    case path(word, folder, dir, vars) do
      {:ok, path} ->
        vm? = is_binary(workspace) and inside?(path, Path.join(workspace, "from-vm"))
        Map.merge(%{file: shown, path: path, why: nil, vm?: vm?}, read(path))

      {:error, why} ->
        unknown(shown, why)
    end
  end

  defp unknown(shown, why),
    do: %{file: shown, path: nil, why: why, vm?: false, hash: nil, size: 0, content: ""}

  # Where a file is: from `/`, `~` or the workspace as it says, or from
  # the folder its command is in after the `cd`s before it.
  defp path(word, folder, dir, vars) do
    case ScriptRuns.value(word, vars) do
      :error ->
        {:error, "whose path holds a variable MWT can't tell"}

      {:ok, text} ->
        if Path.type(text) == :absolute do
          {:ok, Path.expand(text)}
        else
          with {:ok, folder} <- folder(folder, dir, vars), do: {:ok, Path.expand(text, folder)}
        end
    end
  end

  defp folder(:unknown, _dir, _vars), do: {:error, "after a cd MWT can't follow"}

  defp folder(steps, dir, vars) do
    Enum.reduce_while(steps, {:ok, dir}, fn
      :home, _at ->
        {:cont, {:ok, vars["HOME"]}}

      {:cd, word, sure?}, {:ok, at} ->
        case ScriptRuns.value(word, vars) do
          :error ->
            {:halt, {:error, "after cd #{word.text}, a folder MWT can't tell"}}

          {:ok, text} ->
            next = Path.expand(text, at)

            # A cd whose failure doesn't stop the command: should the
            # folder not be there, what follows runs where it was.
            if sure? or dir?(next),
              do: {:cont, {:ok, next}},
              else:
                {:halt,
                 {:error, "after cd #{word.text}, which isn't there now: it would run elsewhere"}}
        end
    end)
  end

  # The home the command runs with (`MWTClient.Sandbox.HostRun`).
  defp home do
    case MWTClient.Sandbox.HostRun.home_env() do
      [{"HOME", home}] -> home
      [] -> System.user_home!()
    end
  end

  @doc """
  The pins whose file is no longer as it was, each with what it is now:
  `{pinned, now}`. A file that was missing counts as changed once it is
  there, and the other way round. One MWT can't tell the path of is
  never looked at: the card said so, and you let it run as it is then.
  """
  @spec changed([pin()]) :: [{pin(), pin()}]
  def changed(pins) do
    for %{path: path} = pin <- pins,
        is_binary(path),
        now = Map.merge(pin, read(path)),
        now.hash != pin.hash,
        do: {pin, now}
  end

  @doc """
  The files a saved command's run found (`now`) that aren't as the
  command keeps them (`pinned`): each `{was, now}`, `was` with no hash
  when it wasn't pinned. A file not pinned yet counts as changed, but
  one missing then and now; a file MWT can't tell the path of always
  does, since nothing says it is what you saw: each run with one asks.

      iex> alias MWTClient.Sandbox.Pins
      iex> a = %{file: "a", path: "/a", why: nil, vm?: false, hash: "1", size: 1, content: "x"}
      iex> unknown = %{a | file: "$X", path: nil, why: "whose path holds a variable MWT can't tell", hash: nil}
      iex> Pins.moved([a, unknown], [a, unknown]) |> Enum.map(fn {_was, now} -> now.file end)
      ["$X"]
      iex> Pins.moved([a], [%{a | hash: "2"}]) |> Enum.map(fn {was, now} -> {was.hash, now.hash} end)
      [{"1", "2"}]
  """
  @spec moved([pin()], [pin()]) :: [{pin(), pin()}]
  def moved(pinned, now) do
    by_path = for %{path: path} = pin <- pinned, is_binary(path), into: %{}, do: {path, pin}

    for pin <- now,
        was = Map.get(by_path, pin.path, %{pin | hash: nil, size: 0, content: ""}),
        is_nil(pin.path) or was.hash != pin.hash,
        do: {was, pin}
  end

  @doc """
  The lines that differ between what a file held and holds, for a card:
  each `{:del, line}` or `{:ins, line}`, at most `most` of them.

      iex> MWTClient.Sandbox.Pins.diff("a\\nb\\nc", "a\\nB\\nc")
      [del: "b", ins: "B"]
  """
  @spec diff(String.t(), String.t(), pos_integer()) :: [{:del | :ins, String.t()}]
  def diff(before, now, most \\ 40) do
    before
    |> String.split("\n")
    |> List.myers_difference(String.split(now, "\n"))
    |> Enum.flat_map(fn
      {:eq, _lines} -> []
      {kind, lines} -> Enum.map(lines, &{kind, &1})
    end)
    |> Enum.take(most)
  end

  defp inside?(path, folder), do: path == folder or String.starts_with?(path, folder <> "/")

  defp dir?(path) do
    match?({:ok, info} when elem(info, 2) == :directory, :file.read_file_info(path, [:raw]))
  end

  defp read(nil), do: %{hash: nil, size: 0, content: ""}

  # Raw, past Erlang's one file server: every command's check reads them.
  defp read(path) do
    with {:ok, info} <- :file.read_file_info(path, [:raw]),
         :regular <- elem(info, 2),
         {:ok, device} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        {hash, content} = hash(device, :crypto.hash_init(:sha256), "")

        %{
          hash: Base.encode16(hash, case: :lower),
          size: elem(info, 1),
          content: String.replace_invalid(content, "�")
        }
      after
        :file.close(device)
      end
    else
      _not_a_file -> %{hash: nil, size: 0, content: ""}
    end
  end

  defp hash(device, state, shown) do
    case :file.read(device, 64 * 1024) do
      {:ok, data} ->
        shown =
          if byte_size(shown) < @shown,
            do: shown <> binary_part(data, 0, min(byte_size(data), @shown - byte_size(shown))),
            else: shown

        hash(device, :crypto.hash_update(state, data), shown)

      _end ->
        {:crypto.hash_final(state), shown}
    end
  end
end
