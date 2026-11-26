defmodule MWTClient.Sandbox.TaskBase do
  @moduledoc """
  Resolves a handoff's comparison branch or commit without changing the
  VM's history. The branch's tracked `host-origin` branch is preferred,
  then the project's default host branch. An explicit --onto overrides
  that choice. A base may also be a branch of your repository's own remote
  (`remote-origin/BRANCH`), for work on top of what others pushed. For a branch you made yourself, `came_from/3` finds the
  base it came from, to make it a task. Bases recorded before the remotes were renamed
  (`refs/remotes/origin/*`, `refs/remotes/host/*`) stay readable: handoff
  records keep them, and so does a closed project's clone until it is
  opened again.
  """

  alias MWTClient.Sandbox.{HostGit, Project, Shown}

  def resolve(project, guest, value \\ nil) do
    resolve_at(project, guest, Project.mirror_path(project, guest), value)
  end

  defp resolve_at(project, guest, top, value) do
    value = blank(value) || project.mirrored_branch

    case remote_branch(value) do
      nil -> resolve_named(project, guest, top, value)
      name -> resolve_remote(guest, top, name)
    end
  end

  # A branch of your repository's own remote, as the clone last fetched it
  # (`remote-origin/NAME`): what a teammate pushed, before your branch has
  # it. Like a VM ref, it is compared from the shared ancestor.
  defp resolve_remote(guest, top, name) do
    ref = remote_ref(name)

    with true <- branch_name?(name),
         {:ok, text} <- guest.exec.(["git", "-C", top, "merge-base", "HEAD", ref]),
         commit = String.trim(text),
         true <- commit?(commit) do
      {:ok, %{ref: ref, branch: nil, commit: commit}}
    else
      _ -> {:error, {:no_base, Shown.text("remote-origin/" <> name)}}
    end
  end

  @doc """
  The branch of your repository's own remote a base names
  (`remote-origin/main`, `refs/remotes/remote-origin/main`: `main`), or nil.
  """
  @spec remote_branch(String.t() | nil) :: String.t() | nil
  def remote_branch("refs/remotes/remote-origin/" <> name) when name != "", do: name
  def remote_branch("remote-origin/" <> name) when name != "", do: name
  def remote_branch(_value), do: nil

  @doc "The ref the branch `name` of your repository's own remote has in the VM's clone."
  @spec remote_ref(String.t()) :: String.t()
  def remote_ref(name), do: "refs/remotes/remote-origin/" <> name

  defp resolve_named(project, guest, top, value) do
    branch =
      case value do
        "refs/remotes/host-origin/" <> name -> name
        "refs/remotes/origin/" <> name -> name
        "refs/remotes/host/" <> name -> name
        "host-origin/" <> name -> name
        "origin/" <> name -> name
        "host/" <> name -> name
        "refs/" <> _ -> nil
        text -> if text =~ ~r/\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z/, do: nil, else: text
      end

    host =
      if branch && not String.starts_with?(branch, "-") do
        HostGit.line(project.path, [
          "rev-parse",
          "--verify",
          "--end-of-options",
          "refs/heads/#{branch}^{commit}"
        ])
      end

    cond do
      commit?(host) ->
        {:ok, %{ref: ref(branch), branch: branch, commit: host}}

      String.starts_with?(value, ["-", "host-origin/", "origin/", "host/", "refs/remotes/"]) ->
        {:error, {:no_base, Shown.text(value)}}

      true ->
        refs =
          if String.starts_with?(value, "refs/"),
            do: [value],
            else: [value, "refs/heads/" <> value]

        Enum.find_value(refs, fn ref ->
          # A local comparison starts at the shared ancestor, even when
          # that local branch has continued since this work began.
          case guest.exec.(["git", "-C", top, "merge-base", "HEAD", ref]) do
            {:ok, text} ->
              commit = String.trim(text)
              if commit?(commit), do: {:ok, %{ref: ref, branch: nil, commit: commit}}

            _ ->
              nil
          end
        end) || {:error, {:no_base, Shown.text(value)}}
    end
  end

  def label(%{branch: branch}) when is_binary(branch), do: branch
  def label(%{ref: ref}), do: ref_label(ref)

  @doc "The ref your branch `branch` has in the VM's clone."
  @spec ref(String.t()) :: String.t()
  def ref(branch), do: "refs/remotes/host-origin/" <> branch

  def ref_label("refs/remotes/host-origin/" <> branch), do: branch
  def ref_label("refs/remotes/origin/" <> branch), do: branch
  def ref_label("refs/remotes/host/" <> branch), do: branch
  def ref_label("refs/remotes/remote-origin/" <> branch), do: "remote-origin/" <> branch
  def ref_label("refs/heads/" <> branch), do: branch
  def ref_label(ref), do: if(commit?(ref), do: binary_part(ref, 0, 12), else: ref)

  def read(project, guest, source, override \\ nil, existing \\ nil) do
    configured =
      git_line(guest, source.top, ["config", "--get", "branch.#{source.branch}.mwt-base"])

    upstream = git_line(guest, source.top, ["rev-parse", "--symbolic-full-name", "@{upstream}"])

    upstream =
      case upstream do
        "refs/remotes/host-origin/" <> _ -> upstream
        "refs/remotes/origin/" <> _ -> upstream
        "refs/remotes/host/" <> _ -> upstream
        _ -> nil
      end

    previous = existing && (existing.base_branch || existing.base_ref)

    value =
      blank(override) || previous || blank(configured) || upstream || project.mirrored_branch

    resolve_at(project, guest, source.top, value)
  end

  @doc """
  The base a branch that `mwt worktree new` didn't start came from, as git
  recorded it when it was made, for making it a task: the start point in
  the branch's own reflog (`branch: Created from X`), else, for a branch
  made from where you were (`git switch -c NAME`, which records only
  `HEAD`), the oldest switch onto it in the HEAD reflog of its worktree
  (`checkout: moving from X to NAME`). `X` becomes a base the way a person
  means it: `host-origin/main` and `remote-origin/main` your `main`; a
  local branch the VM task it is (`refs/heads/X`, work stacked on it), else
  the branch of yours it tracks, else itself.

  Returns the base and what git said `X` was, or `:unknown`: made from no
  branch (a slot is on none until a task takes it), its reflog expired or
  turned off, or `X` no longer a base. Reads only the most recent
  1000 moves of HEAD.
  """
  @spec came_from(Project.t(), map(), %{top: Path.t(), branch: String.t()}) ::
          {:ok, map(), String.t()} | :unknown
  def came_from(project, guest, %{top: top, branch: branch}) do
    with from when is_binary(from) <-
           created_from(guest, top, branch) || switched_from(guest, top, branch),
         true <- from != branch and branch_name?(from),
         {:ok, base} <- resolve_at(project, guest, top, as_base(guest, top, from)) do
      {:ok, base, from}
    else
      _ -> :unknown
    end
  end

  defp created_from(guest, top, branch) do
    case git_lines(guest, top, ["reflog", "show", "--format=%gs", "refs/heads/" <> branch]) do
      [_ | _] = lines ->
        case List.last(lines) do
          "branch: Created from HEAD" -> nil
          "branch: Created from " <> from -> from
          _ -> nil
        end

      [] ->
        nil
    end
  end

  defp switched_from(guest, top, branch) do
    suffix = " to " <> branch

    guest
    |> git_lines(top, ["reflog", "show", "-n", "1000", "--format=%gs", "HEAD"])
    |> Enum.flat_map(fn
      "checkout: moving from " <> rest ->
        if String.ends_with?(rest, suffix),
          do: [String.replace_suffix(rest, suffix, "")],
          else: []

      _ ->
        []
    end)
    |> List.last()
  end

  # Whether $2 is a branch of the repository at $1 (`branch`), then
  # `task` when a task's base is recorded for it, else the branch it
  # tracks, if any.
  @local_branch """
  top=$1 b=$2
  git -C "$top" rev-parse -q --verify "refs/heads/$b" >/dev/null || exit 0
  echo branch
  if git -C "$top" config --get "branch.$b.mwt-base" >/dev/null; then echo task; exit 0; fi
  git -C "$top" rev-parse -q --symbolic-full-name "$b@{upstream}" 2>/dev/null || true
  """

  # A name git recorded, as a branch's: no commit ID (a worktree on no
  # branch), nothing a command would read as an option.
  defp branch_name?(from) do
    from =~ ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z" and not commit_id?(from)
  end

  defp commit_id?(text), do: text =~ ~r/\A[0-9a-f]{7,64}\z/

  # What a branch was made from, as a base `resolve_at/4` reads.
  defp as_base(_guest, _top, "refs/remotes/host-origin/" <> name), do: "host-origin/" <> name
  defp as_base(_guest, _top, "host-origin/" <> _ = from), do: from
  defp as_base(_guest, _top, "refs/remotes/remote-origin/" <> name), do: "host-origin/" <> name
  defp as_base(_guest, _top, "remote-origin/" <> name), do: "host-origin/" <> name

  defp as_base(guest, top, from) do
    name = String.replace_prefix(from, "refs/heads/", "")

    case guest.exec.(["sh", "-c", @local_branch, "mwt-base", top, name]) do
      {:ok, text} ->
        case String.split(text, "\n", trim: true) do
          ["branch", "task" | _] -> "refs/heads/" <> name
          ["branch", "refs/remotes/host-origin/" <> yours | _] -> "host-origin/" <> yours
          _ -> name
        end

      {:error, _} ->
        name
    end
  end

  defp git_lines(guest, top, args) do
    case guest.exec.(["git", "-C", top | args]) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  # Kept for legacy callers; ordinary clones need no task reservation.
  def remember(guest, source, base) do
    case guest.exec.([
           "git",
           "-C",
           source.top,
           "config",
           "branch.#{source.branch}.mwt-base",
           base.ref
         ]) do
      {:ok, _} -> :ok
      {:error, text} -> {:error, Shown.text(text)}
    end
  end

  def current(_guest, _source, _base), do: :ok

  defp git_line(guest, top, args) do
    case guest.exec.(["git", "-C", top | args]) do
      {:ok, text} -> blank(String.trim(text))
      _ -> nil
    end
  end

  defp commit?(value) when is_binary(value), do: value =~ ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  defp commit?(_), do: false
  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
