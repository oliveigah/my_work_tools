defmodule MWTClient.ReviewsCase do
  @moduledoc """
  mwt review, as you or an agent run it in a slot (`MWTClient.Sandbox.Reviews`):
  a project with slots (`MWTClient.HandoffsCase`), whose repository's own
  remote holds a colleague's pull request, through the same fetches the
  VM makes (host-origin, remote-origin and a pull request's head that your
  machine fetched into MWT's store).
  """
  use ExUnit.CaseTemplate

  import MWTClient.HandoffsCase

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{HandoffStore, Server}

  using do
    quote do
      use MWTClient.HandoffsCase, async: true
      import MWTClient.ReviewsCase

      # After HandoffsCase's own setup, which makes the identity and your repository.
      setup {MWTClient.ReviewsCase, :with_pull_request}
    end
  end

  @doc """
  The project with slot-1 to slot-3 (`MWTClient.HandoffsCase.with_slots/1`),
  Git: fetch from your remotes on, and `remote_with_pull_request/1`.
  """
  def with_pull_request(context) do
    :ok = with_slots(context)
    {:ok, _} = Sandbox.turn_on(context.username, "git-fetch-remote", :until_off, :all)
    remote_with_pull_request(context)
  end

  @doc """
  Your repository's own remote, a Git server standing in for GitHub: a
  colleague's pull request kept only as `refs/pull/7/head` (as a fork's
  is), branched from master before master moved on.
  """
  def remote_with_pull_request(%{repo: repo, base: base}) do
    commit(repo, [{"c.txt", "gone soon\n"}], "c")
    server = Path.join(base, "server.git")
    git(base, ["clone", "-q", "--bare", repo, server])
    git(repo, ["remote", "add", "origin", server])
    git(repo, ["fetch", "-q", "origin"])

    colleague = Path.join(base, "colleague")
    git(base, ["clone", "-q", server, colleague])
    git(colleague, ["switch", "-q", "-c", "work"])
    File.rm!(Path.join(colleague, "c.txt"))
    commit(colleague, [{"a.txt", "one\nTWO\nthree\n"}, {"b.txt", "new\n"}], "their change")
    git(colleague, ["push", "-q", "origin", "HEAD:refs/pull/7/head"])

    git(colleague, ["switch", "-q", "master"])
    commit(colleague, [{"m.txt", "later\n"}], "later on master")
    git(colleague, ["push", "-q", "origin", "master"])
    git(colleague, ["switch", "-q", "work"])

    %{server: server, colleague: colleague, parted: sha(repo, "master")}
  end

  @doc "`git status --porcelain`, a line each."
  def status(dir), do: dir |> git(["status", "--porcelain"]) |> String.split("\n", trim: true)

  @doc "MWT's store for your repository, where a review's fetches go."
  def store(%{username: username, repo: repo}),
    do: HandoffStore.path(Server.call(username, :projects).dir, repo)
end
