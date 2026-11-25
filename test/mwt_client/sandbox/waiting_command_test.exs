defmodule MWTClient.Sandbox.WaitingCommandTest do
  @moduledoc """
  A run or a call that waits for you is carried out only under what it was
  asked under: its grant turned off, out of time, removed or edited refuses
  it, and Run looks again before anything runs or is sent, the value's
  mint included. How a saved command runs is fixed into its card.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server
  alias MWTClient.Vault.Store

  setup do
    base = Path.join(System.tmp_dir!(), "waiting-command-#{System.unique_integer([:positive])}")
    dir = Path.join(base, "work")
    outside = Path.join(base, "outside")
    File.mkdir_p!(dir)
    File.mkdir_p!(outside)
    secret = Path.join(outside, "secret.txt")
    File.write!(secret, "SECRET-OUTSIDE-THE-FOLDER\n")
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)

    MWTClient.VaultHelpers.unlocked_identity("waiting-command")
    |> Map.merge(%{dir: dir, secret: secret, base: base})
  end

  defp peek(context, attrs \\ %{}) do
    {:ok, grant} =
      Sandbox.create_grant(
        context.username,
        Map.merge(
          %{
            "kind" => "command",
            "name" => "peek",
            "purpose" => "Shows a file of the folder",
            "script" => "cat #{context.secret} 2>&1 || echo NOT-VISIBLE",
            "dir" => context.dir,
            "confined" => "true"
          },
          attrs
        )
      )

    {:ok, grant} = Sandbox.turn_on(context.username, grant.id, 60, :ask)
    grant
  end

  defp call(username, id) do
    ask = %{grant: id, script: nil, values: %{}, dir: nil, reason: "look", agent: "claude"}
    {:ok, approval} = Server.call(username, {:call, ask})
    approval
  end

  # The card as the agent waiting on it hears of it, once it is final.
  defp final(username, id) do
    {:ok, approval, _grant} = Server.call(username, {:await, id, 10_000}, 15_000)
    approval
  end

  defp waiting?(username, id),
    do: Enum.any?(Sandbox.snapshot(username).waiting, &(&1.id == id))

  defp token(context, mint) do
    {:ok, token} =
      Sandbox.create_grant(context.username, %{
        "kind" => "token",
        "name" => "Svc",
        "purpose" => "A service",
        "hosts" => "localhost, other.localhost",
        "source" => "minted",
        "mint" => mint
      })

    {:ok, sub} =
      Sandbox.create_grant(context.username, %{
        "kind" => "request",
        "credential" => token.credential,
        "name" => "who",
        "purpose" => "Who am I",
        "method" => "GET",
        "url" => "https://localhost/user",
        "headers" => "Authorization: Bearer {token}"
      })

    {:ok, sub} = Sandbox.turn_on(context.username, sub.id, 60, :ask)
    {token, sub}
  end

  test "a saved command's card says how it runs, and Run runs it so", context do
    grant = peek(context)
    card = call(context.username, grant.id)
    assert card.confine == %{confined: true, with: [], writes_dir: false}
    assert {"Runs", "Confined: no home of yours, your tools read-only"} in card.facts

    :ok = Sandbox.decide(context.username, card.id, {:run, :send})
    ran = final(context.username, card.id)
    # Confined: the file is out of its reach, or, where no bubble can be
    # made, it doesn't run at all.
    assert ran.run.output =~ "NOT-VISIBLE" or ran.run.error =~ "confined"
    refute ran.run.output =~ "SECRET"
  end

  test "turning an action off refuses the run waiting for it", context do
    grant = peek(context)
    card = call(context.username, grant.id)

    {:ok, _} = Sandbox.turn_off(context.username, grant.id)
    refute waiting?(context.username, card.id)
    assert {:error, :not_waiting} = Sandbox.decide(context.username, card.id, {:run, :send})

    refused = final(context.username, card.id)
    assert {refused.status, refused.decision, refused.run} == {:denied, :grant_off, nil}
  end

  test "removing a confined action refuses its waiting run: nothing runs as you", context do
    grant = peek(context)
    card = call(context.username, grant.id)

    :ok = Sandbox.delete_grant(context.username, grant.id)
    refute waiting?(context.username, card.id)
    assert {:error, :not_waiting} = Sandbox.decide(context.username, card.id, {:run, :send})
    assert %{decision: :grant_off, run: nil} = final(context.username, card.id)
  end

  test "an action's time running out refuses the run waiting for it", context do
    grant = peek(context)
    card = call(context.username, grant.id)
    server = Store.whereis(Server, context.username)

    # Its hour is over, as the clock says, before any timer fired.
    :sys.replace_state(server, fn state ->
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      %{
        state
        | grants:
            Enum.map(state.grants, &if(&1.id == grant.id, do: %{&1 | expires_at: past}, else: &1))
      }
    end)

    send(server, :sweep)
    :sys.get_state(server)
    refute waiting?(context.username, card.id)
    assert %{decision: :grant_off} = final(context.username, card.id)
  end

  test "an edit of what an action runs refuses its waiting runs; a new name keeps them",
       context do
    grant = peek(context)
    kept = call(context.username, grant.id)

    edit = fn attrs ->
      Sandbox.update_grant(
        context.username,
        grant.id,
        Map.merge(
          %{
            "name" => "peek",
            "purpose" => "Shows a file of the folder",
            "script" => "cat #{context.secret} 2>&1 || echo NOT-VISIBLE",
            "dir" => context.dir,
            "confined" => "true"
          },
          attrs
        )
      )
    end

    {:ok, _} = edit.(%{"name" => "peek a file"})
    assert waiting?(context.username, kept.id)

    # Unconfined now: the card asked confined is refused, not run as you.
    {:ok, _} = edit.(%{"name" => "peek a file", "confined" => ""})
    refute waiting?(context.username, kept.id)
    assert %{decision: :changed, run: nil} = final(context.username, kept.id)
  end

  test "Run looks again: a card whose grant changed since it was asked is refused", context do
    grant = peek(context)
    card = call(context.username, grant.id)
    server = Store.whereis(Server, context.username)

    # Changed by a way that refused nothing, as an older MWT's edit did.
    :sys.replace_state(server, fn state ->
      %{
        state
        | grants:
            Enum.map(state.grants, &if(&1.id == grant.id, do: %{&1 | confined: false}, else: &1))
      }
    end)

    assert waiting?(context.username, card.id)
    :ok = Sandbox.decide(context.username, card.id, {:run, :send})
    refused = final(context.username, card.id)
    assert {refused.decision, refused.run} == {:changed, nil}
  end

  test "a call whose host's network no longer lets it out is refused at Run, before any mint",
       context do
    marker = Path.join(context.base, "minted")
    {_token, sub} = token(context, "touch #{marker}; exit 1")
    card = call(context.username, sub.id)

    # Its URL's host is on the Internet, whose grant you turn off: its
    # request would go out as the agent's own, which that grant lets out.
    {:ok, _} = Sandbox.turn_off(context.username, "internet")
    assert waiting?(context.username, card.id)
    :ok = Sandbox.decide(context.username, card.id, {:run, :send})
    assert %{decision: :grant_off, run: nil} = final(context.username, card.id)
    refute File.exists?(marker)
  end

  test "turning a request action off refuses its waiting call", context do
    marker = Path.join(context.base, "minted")
    {_token, sub} = token(context, "touch #{marker}; exit 1")
    card = call(context.username, sub.id)

    {:ok, _} = Sandbox.turn_off(context.username, sub.id)
    refute waiting?(context.username, card.id)
    assert %{decision: :grant_off} = final(context.username, card.id)
    refute File.exists?(marker)
  end

  test "a call is sent only if its action still allows it once the value is at hand",
       context do
    go = Path.join(context.base, "go")
    # A mint that takes as long as the test needs: until `go` exists.
    {_token, sub} =
      token(context, "until [ -e #{go} ]; do sleep 0.05; done; echo minted-value-0123456789")

    card = call(context.username, sub.id)
    :ok = Sandbox.decide(context.username, card.id, {:run, :send})

    # Running: its mint is under way. You turn the action off meanwhile.
    {:ok, _} = Sandbox.turn_off(context.username, sub.id)
    File.write!(go, "")

    sent = final(context.username, card.id)
    assert sent.run.state == :done
    assert sent.run.error =~ "a grant it needs no longer gives it"
    assert is_nil(sent.run.status)
  end
end
