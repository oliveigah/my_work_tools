defmodule MWTClientWeb.GitLive.SessionTest do
  # Not async: what the Git tool kept before was in the app-wide
  # preferences, which this writes.
  use MWTClientWeb.ConnCase, async: false

  import MWTClient.GitHelpers
  import MWTClientWeb.GitLiveHelpers
  import Phoenix.LiveViewTest

  alias MWTClient.Preferences
  alias MWTClientWeb.GitLive.Session

  @legacy ~w(git_repositories git_active_repository git_ssh_private_key git_ssh_public_key)

  setup do
    on_exit(fn -> Enum.each(@legacy, &Preferences.delete/1) end)
  end

  test "what the preferences kept goes to the first identity to open the tool, and leaves them",
       %{conn: conn} do
    %{path: path, base: base} = initialized_repository(%{})
    {private_key, public_key} = ssh_key_pair(base)
    :ok = Preferences.put("git_repositories", [path])
    :ok = Preferences.put("git_active_repository", path)
    :ok = Preferences.put("git_ssh_private_key", private_key)
    :ok = Preferences.put("git_ssh_public_key", public_key)

    %{conn: conn, username: username} = sign_in(conn)
    {:ok, view, _html} = live(conn, ~p"/tools/git")
    render_async(view)

    assert count(view, "#git-tabs [role=tab]") == 1
    assert render(view) =~ "SSH ready"
    assert Session.tabs(username) == %{paths: [path], active: path}
    assert Session.ssh_key(username) == %{private_key: private_key, public_key: public_key}
    assert Map.take(Preferences.all(), @legacy) == %{}

    # Another identity finds none of it.
    %{conn: theirs, username: someone} = sign_in(build_conn())
    {:ok, their_view, _html} = live(theirs, ~p"/tools/git")
    render_async(their_view)

    assert has_element?(their_view, "#git-empty-state")
    assert Session.ssh_key(someone) == nil
  end
end
