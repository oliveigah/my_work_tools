defmodule MWTClient.Sandbox.Mirror do
  @moduledoc """
  Opens a project's clone in the VM (the module keeps the mirror's name).
  Later runs read your branches for the Projects page and leave the VM's
  branches, index and files alone.

  A new clone receives your committed branches and tags once, then
  fetches through its MWT origin (`mwt::<id>`) like any clone; its
  `upstream` (`mwt::<id>/upstream`) is your repository's own remote's
  branches (`MWTClient.Sandbox.GitTransport`). Older mirrors become clones
  in place, without moving their checkout or any worktree: their branches
  are copied to `origin/*`, then their `host` remote goes, with its
  branches, which nothing would update any more.
  """

  alias MWTClient.Sandbox.{Guest, HostGit, Project, Shown}

  @type result :: %{
          tips: %{String.t() => String.t()},
          default: String.t(),
          checkout: String.t() | nil,
          rescued: nil,
          identity: %{name: String.t(), email: String.t()} | nil
        }

  def remote_url(project), do: Project.remote_url(project)

  @prepare ~S"""
  set -e
  m=$1
  if [ ! -e "$m/.git" ]; then
    if [ -d "$m" ] && [ -n "$(ls -A "$m")" ]; then
      echo "The project folder already contains files and is not a Git repository." >&2
      exit 1
    fi
    mkdir -p "$m"
    git init -q "$m"
  fi
  if git -C "$m" config --get mwt.clone-version >/dev/null ||
    git -C "$m" config --get mdt.clone-version >/dev/null; then echo ready
  elif git -C "$m" rev-parse --verify --quiet HEAD >/dev/null; then echo migrate
  else echo new; fi
  """

  @configure ~S"""
  set -e
  m=$1 mode=$2 branch=$3 url=$4 id=$5 name=$6 email=$7
  cd "$m"
  if [ "$mode" != ready ]; then
    git config remote.origin.url "$url"
    git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git config mwt.project "$id"
    if [ -n "$name" ] && ! git config user.name >/dev/null; then git config user.name "$name"; fi
    if [ -n "$email" ] && ! git config user.email >/dev/null; then git config user.email "$email"; fi
    if [ "$mode" = migrate ]; then
      git for-each-ref --format='%(objectname) %(refname)' refs/remotes/host/ |
        while read -r sha ref; do
          b=${ref#refs/remotes/host/}
          [ "$b" = HEAD ] && continue
          if ! git show-ref --verify --quiet "refs/remotes/origin/$b"; then
            git update-ref "refs/remotes/origin/$b" "$sha"
          fi
        done
      git config --get-regexp '^branch[.].*[.]remote$' |
        while read -r key remote; do
          [ "$remote" != host ] || git config "$key" origin
        done || true
    else
      git checkout -q --track -b "$branch" "refs/remotes/origin/$branch"
    fi
    git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$branch"
    git config mwt.clone-version 1
  fi
  # Your repository's own remote's branches, through MWT, unless the VM
  # has an upstream of its own.
  if ! git config --get remote.upstream.url >/dev/null; then
    git config remote.upstream.url "$url/upstream"
    git config remote.upstream.fetch '+refs/heads/*:refs/remotes/upstream/*'
  fi
  # A mirror's own remote (mwt::host, MWT's, never the VM's), once origin
  # is there: its branches are origin's now, and nothing updates them.
  # Tasks' recorded bases follow to origin. Each run, so a clone made
  # before this goes too.
  if [ "$(git config --get remote.host.url || true)" = mwt::host ] &&
    git config --get remote.origin.url >/dev/null; then
    git config --get-regexp '^branch[.].*[.]mwt-base$' |
      while read -r key base; do
        case $base in
          refs/remotes/host/*) git config "$key" "refs/remotes/origin/${base#refs/remotes/host/}" ;;
        esac
      done || true
    git remote remove host
  fi
  # A clone made when MWT was MDT: its remotes go through MWT's helper
  # (mwt::), its tasks' keys take MWT's names, and MDT's own keys go. Each
  # run, so any clone comes over.
  for r in origin upstream; do
    u=$(git config --get "remote.$r.url" || true)
    case $u in mdt::*) git config "remote.$r.url" "mwt::${u#mdt::}" ;; esac
  done
  git config --get-regexp '^branch[.].*[.]mdt-(base|thread)$' |
    while read -r key value; do
      git config "${key%.mdt-*}.mwt-${key##*.mdt-}" "$value"
      git config --unset "$key"
    done || true
  for k in clone-version project; do
    v=$(git config --get "mdt.$k" || true)
    [ -z "$v" ] || git config "mwt.$k" "$v"
  done
  git config --remove-section mdt 2>/dev/null || true
  git symbolic-ref -q --short HEAD || true
  """

  @doc "Every committed local host branch tip, for the Projects page."
  @spec tips(Project.t()) :: %{String.t() => String.t()}
  def tips(%Project{path: path}) do
    case HostGit.run(path, ["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads/"]) do
      {:ok, output} ->
        for line <- String.split(output, "\n", trim: true),
            [sha, "refs/heads/" <> branch] <- [String.split(line, " ", parts: 2)],
            into: %{},
            do: {branch, sha}

      {:error, _} ->
        %{}
    end
  end

  @spec run(Project.t(), Guest.t()) :: {:ok, result()} | {:error, String.t()}
  def run(%Project{path: path, mirrored_branch: kept} = project, guest) do
    clone = Project.mirror_path(project, guest)
    tips = tips(project)

    default =
      if Map.has_key?(tips, kept),
        do: kept,
        else: Project.default_branch(Map.keys(tips), HostGit.branch(path))

    identity = HostGit.identity(path)
    who = if identity, do: [identity.name, identity.email], else: ["", ""]

    with true <- default != nil || {:error, "Your repository has no branch."},
         {:ok, state} <- exec(guest, @prepare, [clone]),
         mode = String.trim(state),
         :ok <- seed(mode, path, guest, clone, Map.keys(tips)),
         {:ok, checkout} <-
           exec(
             guest,
             @configure,
             [clone, mode, default, remote_url(project), Project.id(project)] ++ who
           ) do
      {:ok,
       %{
         tips: tips,
         default: default,
         checkout:
           case String.trim(checkout) do
             "" -> nil
             branch -> branch
           end,
         rescued: nil,
         identity: identity
       }}
    end
  end

  defp exec(guest, script, args) do
    case guest.exec.(["sh", "-c", script, "mwt-project" | args]) do
      {:ok, output} -> {:ok, output}
      {:error, text} -> {:error, "The project could not be opened: " <> Shown.text(text)}
    end
  end

  defp seed("new", path, guest, clone, branches) do
    specs = Enum.map(branches, &"refs/heads/#{&1}:refs/remotes/origin/#{&1}")

    case HostGit.run(
           path,
           ["push", "--porcelain", "--no-verify", "--tags", guest.git_url.(clone) | specs],
           env: guest.env,
           seconds: 600
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp seed(_existing, _path, _guest, _clone, _branches), do: :ok
end
