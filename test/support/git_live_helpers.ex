defmodule MWTClientWeb.GitLiveHelpers do
  @moduledoc """
  What the tests of the Git tool's page share: the page open on an
  identity of the test's own, beside a repository of its own (`tool/1`, a
  setup), and the reads of the page they all make.

  The tool keeps its tabs and SSH key per identity
  (`MWTClientWeb.GitLive.Session`), so the modules that use these run side
  by side.
  """

  import MWTClient.GitHelpers, only: [git!: 2, initialized_repository: 1]
  # `live/2` gets the page through `Phoenix.ConnTest.get/2`, which reads
  # `@endpoint`.
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  alias MWTClientWeb.GitLive.Components

  @endpoint MWTClientWeb.Endpoint

  @doc """
  A setup: signs in (`:conn`, `:username`), makes a repository with one
  commit (`:path`, in `:base`) and opens the Git tool (`:view`), with no
  tab yet.
  """
  def tool(%{conn: conn}) do
    %{conn: conn, username: username} = MWTClientWeb.ConnCase.sign_in(conn)

    context = initialized_repository(%{})
    {:ok, view, _html} = live(conn, "/tools/git")

    Map.merge(context, %{conn: conn, username: username, view: view})
  end

  @doc "Opens the repository at `path` in a tab, as the folder picker does."
  def open(view, path) do
    render_hook(view, "open_repository", %{"path" => path})
    render_async(view)
    view
  end

  @doc "How many elements of the page `selector` matches."
  def count(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  @doc "The commit `HEAD` is at, in the repository at `path`."
  def head_commit(path), do: git!(path, ["rev-parse", "HEAD"])

  @doc "The ids of the open tabs, in their order on the page."
  def tab_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#git-tabs [role=tab]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "git-tab-", ""))
  end

  @doc "A name as the page puts it in element ids."
  def slug(value), do: Components.slug(value)
end
