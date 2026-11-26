defmodule MWTClient.QAProbes.Commands.MwtToolsTest do
  @moduledoc """
  Probe: MWT's tools grants (mwt-read, mwt-create, mwt-change, git-fetch,
  git-fetch-remote, git-handoff, share-sync, workspace). Off refuses; MWT
  locked refuses whatever the grant says, *Allow every use* included; an
  add past the hour's limit asks whatever the allowances say, and no
  allowance added later settles its card; host commands locked leaves
  them alone (Q1, Q2). Pure: `MWTClient.Sandbox.Policy.decide/3`.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Allowance, Approval, Grant, Policy}

  @now ~U[2026-11-25 12:00:00Z]
  @every %Allowance{id: "a", pattern: :all, until: nil}

  defp snapshot(state, allowances, locks \\ %{}) do
    grants = for g <- Grant.mwt_tools(), do: %{g | state: state, allowances: allowances}
    %{grants: grants, own: [], resolve: fn _ -> [] end, locks: locks}
  end

  defp uses do
    [
      %{grant: :read, tool: "list_notes"},
      %{grant: :create, tool: "create_note", kind: :note},
      %{grant: :change, tool: "update_note", kind: :note, id: "n1"},
      %{grant: :git_fetch},
      %{grant: :git_fetch_remote},
      %{grant: :git_handoff},
      %{grant: :share_sync},
      %{grant: :workspace}
    ]
  end

  test "every tool grant is there, one per use" do
    for use <- uses() do
      assert Enum.any?(Grant.mwt_tools(), &(&1.tools == use.grant)), "no grant for #{use.grant}"
    end
  end

  test "off refuses; on with every use allowed lets it through" do
    for use <- uses() do
      assert {:refuse, {:grant_off, _}} =
               Policy.decide(snapshot(:off, [@every]), {:tool, use}, @now)

      assert {:allow, _, _, _} = Policy.decide(snapshot(:on, [@every]), {:tool, use}, @now)
      assert {:ask, _, _} = Policy.decide(snapshot(:on, []), {:tool, use}, @now)
    end
  end

  test "MWT locked refuses, every use allowed or not; host commands locked doesn't" do
    for use <- uses() do
      assert {:refuse, {:locked, :mwt, _}} =
               Policy.decide(snapshot(:on, [@every], %{mwt: [:you]}), {:tool, use}, @now)

      assert {:allow, _, _, _} =
               Policy.decide(snapshot(:on, [@every], %{machine: [:you]}), {:tool, use}, @now)
    end
  end

  test "past the hour's limit an add asks, whatever the allowances; none settles it later" do
    use = %{grant: :create, tool: "create_note", kind: :note, over_limit: true}

    assert {:ask, grant, %{pattern: nil}} =
             Policy.decide(snapshot(:on, [@every]), {:tool, use}, @now)

    card = %Approval{
      id: "c",
      kind: :tool,
      grant_id: grant.id,
      title: "Add a note",
      pattern: nil,
      requested_at: @now,
      deadline: @now
    }

    refute Policy.settles?(card, @every, @now)
    refute Policy.settles?(card, %{@every | pattern: "create"}, @now)
  end
end
