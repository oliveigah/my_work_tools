defmodule MWTClient.Sandbox.TaskBase do
  @moduledoc """
  Resolves a handoff's comparison branch or commit without changing the
  VM's history. The branch's origin upstream is preferred, then the
  project's default host branch. An explicit --onto overrides that choice.
  Older branch.mwt-base settings remain readable during migration.
  """

  alias MWTClient.Sandbox.{HostGit, Project, Shown}

  def resolve(project, guest, value \\ nil) do
    resolve_at(project, guest, Project.mirror_path(project, guest), value)
  end

  defp resolve_at(project, guest, top, value) do
    value = blank(value) || project.mirrored_branch

    branch =
      case value do
        "refs/remotes/origin/" <> name -> name
        "refs/remotes/host/" <> name -> name
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
        {:ok, %{ref: "refs/remotes/origin/" <> branch, branch: branch, commit: host}}

      String.starts_with?(value, ["-", "origin/", "host/", "refs/remotes/"]) ->
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

  def ref_label("refs/remotes/origin/" <> branch), do: branch
  def ref_label("refs/remotes/host/" <> branch), do: branch
  def ref_label("refs/heads/" <> branch), do: branch
  def ref_label(ref), do: if(commit?(ref), do: binary_part(ref, 0, 12), else: ref)

  def read(project, guest, source, override \\ nil, existing \\ nil) do
    configured =
      git_line(guest, source.top, ["config", "--get", "branch.#{source.branch}.mwt-base"])

    upstream = git_line(guest, source.top, ["rev-parse", "--symbolic-full-name", "@{upstream}"])

    upstream =
      case upstream do
        "refs/remotes/origin/" <> _ -> upstream
        "refs/remotes/host/" <> _ -> upstream
        _ -> nil
      end

    previous = existing && (existing.base_branch || existing.base_ref)

    value =
      blank(override) || previous || blank(configured) || upstream || project.mirrored_branch

    resolve_at(project, guest, source.top, value)
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
