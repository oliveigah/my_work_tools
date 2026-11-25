defmodule MWTClient.Sandbox.Pins do
  @moduledoc """
  The files a command on your machine runs, pinned: what you approve is
  each file as it was when you looked, not whatever it holds when it runs
  (docs/grant_mental_model.md, Q10).

  A command's text shows what it runs, but not what a file it runs holds
  (`./deploy.sh`), and that file may change between your look and the run:
  a pull, an edit, or an earlier command the agent wrote. So:

    * a card (a command the agent wrote, or a saved command's run) shows
      each file's content and keeps its hash (`of/3`); just before the
      command runs, MWT hashes the file again, and one changed or gone
      runs nothing (`changed/1`);
    * a saved command keeps them as it is saved; a run whose files changed
      since asks, whatever its setting, its card showing the difference
      (`diff/2`), and running it pins what is there now.

  Which files are the ones the text names (`MWTClient.Sandbox.HostCommand.files_run/1`),
  each resolved in the folder it runs in, with the workspace and your home
  put in for `$MWT_WORKSPACE` and `~`. Not pinned, and said so on the card:
  what a file runs in turn, a file it only reads, a path holding any other
  variable, and a change in the instant between the check and the shell
  opening the file. It catches what happens between your look and the
  run, minutes or weeks apart; not a race designed against it.
  """

  alias MWTClient.Sandbox.HostCommand

  # What a card shows of each file; its hash is of all of it.
  @shown 16 * 1024

  @typedoc """
  One file: as the command names it (`file`), where that is (`path`, nil
  when a variable keeps it from being known), whether the VM wrote it
  (`vm?`, in the workspace's `from-vm/`), and what it holds: its `hash`
  and `size`, and the start of its `content`; `hash` nil when it isn't
  there or can't be read.
  """
  @type pin :: %{
          file: String.t(),
          path: String.t() | nil,
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
    for file <- HostCommand.files_run(script) do
      path = resolve(file, dir, workspace)

      vm? =
        is_binary(path) and is_binary(workspace) and
          inside?(path, Path.join(workspace, "from-vm"))

      Map.merge(%{file: file, path: path, vm?: vm?}, read(path))
    end
  end

  @doc """
  The pins whose file is no longer as it was, each with what it is now:
  `{pinned, now}`. A file that was missing counts as changed once it is
  there, and the other way round; one whose path wasn't known is never
  looked at.
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

  defp resolve(file, dir, workspace) do
    expanded =
      file
      |> then(
        &if(workspace, do: String.replace(&1, ~r/\$\{?MWT_WORKSPACE\}?/, workspace), else: &1)
      )
      |> then(
        &if(String.starts_with?(&1, "~/"),
          do: Path.join(System.user_home!(), String.slice(&1, 2..-1//1)),
          else: &1
        )
      )

    if String.contains?(expanded, "$"), do: nil, else: Path.expand(expanded, dir)
  end

  defp inside?(path, folder), do: path == folder or String.starts_with?(path, folder <> "/")

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
