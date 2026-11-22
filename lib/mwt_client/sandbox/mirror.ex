defmodule MWTClient.Sandbox.Mirror do
  @moduledoc """
  Opens a project's clone in the VM (the module keeps the mirror's name).
  Later runs read your branches for the Projects page and leave the VM's
  branches, index and files alone.

  A new clone receives your committed branches and tags once, then
  fetches through MWT like any clone, from two remotes named for the level
  they reach (`MWTClient.Sandbox.GitTransport`): `host-origin`
  (`mwt::<id>`), your repository on your machine, and `remote-origin`
  (`mwt::<id>/remote-origin`), your repository's own remote `origin`, as
  your machine fetches it. `origin` alone would mean your repository in
  the VM and its remote on your machine, and agents, messages and you
  mixed the two up; the cost is Git's default name, so a bare `git fetch`
  or `git pull` with no tracking branch names no remote.

  Clones made before (`mwt.clone-version` 1, with `origin` and `upstream`)
  are renamed in place at the next run, their tracking branches and tasks'
  recorded bases with them. Older mirrors become clones in place, without
  moving their checkout or any worktree: their branches are copied to
  `host-origin/*`, then their `host` remote goes, with its branches, which
  nothing would update any more.
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
  case $(git -C "$m" config --get mwt.clone-version || true) in
    2) echo ready ;;
    ?*) echo rename ;;
    *) if git -C "$m" rev-parse --verify --quiet HEAD >/dev/null; then echo migrate; else echo new; fi ;;
  esac
  """

  @configure ~S"""
  set -e
  m=$1 mode=$2 branch=$3 url=$4 id=$5 name=$6 email=$7
  cd "$m"
  # Version 1 named your repository origin and its remote upstream: each
  # is renamed when it is still MWT's, and the tasks' recorded bases
  # follow. One the VM pointed elsewhere stays the VM's, under its name.
  if [ "$mode" = rename ]; then
    if [ "$(git config --get remote.origin.url || true)" = "$url" ] &&
      ! git config --get remote.host-origin.url >/dev/null; then
      git remote rename origin host-origin
      git config --get-regexp '^branch[.].*[.]mwt-base$' |
        while read -r key base; do
          case $base in
            refs/remotes/origin/*) git config "$key" "refs/remotes/host-origin/${base#refs/remotes/origin/}" ;;
          esac
        done || true
    fi
    if [ "$(git config --get remote.upstream.url || true)" = "$url/upstream" ] &&
      ! git config --get remote.remote-origin.url >/dev/null; then
      git remote rename upstream remote-origin
      git config remote.remote-origin.url "$url/remote-origin"
    fi
  fi
  if [ "$mode" = new ] || [ "$mode" = migrate ] ||
    { [ "$mode" = rename ] && ! git config --get remote.host-origin.url >/dev/null; }; then
    git config remote.host-origin.url "$url"
    git config remote.host-origin.fetch '+refs/heads/*:refs/remotes/host-origin/*'
  fi
  if [ "$mode" = new ] || [ "$mode" = migrate ]; then
    git config mwt.project "$id"
    if [ -n "$name" ] && ! git config user.name >/dev/null; then git config user.name "$name"; fi
    if [ -n "$email" ] && ! git config user.email >/dev/null; then git config user.email "$email"; fi
    if [ "$mode" = migrate ]; then
      git for-each-ref --format='%(objectname) %(refname)' refs/remotes/host/ |
        while read -r sha ref; do
          b=${ref#refs/remotes/host/}
          [ "$b" = HEAD ] && continue
          if ! git show-ref --verify --quiet "refs/remotes/host-origin/$b"; then
            git update-ref "refs/remotes/host-origin/$b" "$sha"
          fi
        done
      git config --get-regexp '^branch[.].*[.]remote$' |
        while read -r key remote; do
          [ "$remote" != host ] || git config "$key" host-origin
        done || true
    else
      git checkout -q --track -b "$branch" "refs/remotes/host-origin/$branch"
    fi
    git symbolic-ref refs/remotes/host-origin/HEAD "refs/remotes/host-origin/$branch"
  fi
  git config mwt.clone-version 2
  # Your repository's own remote's branches, through MWT, unless the VM
  # has a remote-origin of its own.
  if ! git config --get remote.remote-origin.url >/dev/null; then
    git config remote.remote-origin.url "$url/remote-origin"
    git config remote.remote-origin.fetch '+refs/heads/*:refs/remotes/remote-origin/*'
  fi
  # A mirror's own remote (mwt::host, MWT's, never the VM's), once
  # host-origin is there: its branches are host-origin's now, and nothing
  # updates them. Tasks' recorded bases follow to host-origin. Each run,
  # so a clone made before this goes too.
  if [ "$(git config --get remote.host.url || true)" = mwt::host ] &&
    git config --get remote.host-origin.url >/dev/null; then
    git config --get-regexp '^branch[.].*[.]mwt-base$' |
      while read -r key base; do
        case $base in
          refs/remotes/host/*) git config "$key" "refs/remotes/host-origin/${base#refs/remotes/host/}" ;;
        esac
      done || true
    git remote remove host
  fi
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
    specs = Enum.map(branches, &"refs/heads/#{&1}:refs/remotes/host-origin/#{&1}")

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
