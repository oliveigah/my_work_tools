defmodule MWTClient.FormerNameTest do
  use ExUnit.Case, async: true

  alias MWTClient.FormerName
  alias MWTClient.Sandbox.{Grant, Snapshot}
  alias MWTClient.Storage.Values
  alias MWTClient.Vault

  doctest FormerName

  @moduletag :tmp_dir

  describe "data_dir/2" do
    test "an install MDT made stays in its folder", %{tmp_dir: tmp_dir} do
      former = Path.join(tmp_dir, ".mdt_client")
      current = Path.join(tmp_dir, ".mwt_client")
      File.mkdir_p!(former)

      assert FormerName.data_dir(former, current) == former
      refute File.exists?(current)
    end

    test "MWT's folder once it is there, or with no MDT", %{tmp_dir: tmp_dir} do
      former = Path.join(tmp_dir, ".mdt_client")
      current = Path.join(tmp_dir, ".mwt_client")

      assert FormerName.data_dir(former, current) == current

      File.mkdir_p!(former)
      File.mkdir_p!(current)
      assert FormerName.data_dir(former, current) == current
    end
  end

  test "a VM of this install has MWT's names, as its data folder isn't MDT's" do
    assert FormerName.name() == "mwt"
  end

  # A term as MDT wrote it: its modules' names, its grant kind.
  defp mdt_term do
    snapshot =
      %Snapshot{id: "s1", tag: "2026-11-12.1", taken_at: ~U[2026-11-12 10:00:00Z]}
      |> Map.put(:__struct__, :"Elixir.MDTClient.Sandbox.Snapshot")

    %{version: 1, snapshots: [snapshot], grants: [%{id: "mdt-read", kind: :mdt}]}
  end

  test "a term MDT sealed opens as MWT's" do
    key = :crypto.strong_rand_bytes(32)

    assert {:ok, %{snapshots: [%Snapshot{id: "s1"}], grants: [%{kind: :mwt}]}} =
             Vault.open(key, Vault.seal(key, mdt_term()))
  end

  test "a term MDT stored in a column reads as MWT's" do
    {:blob, blob} = Values.term(mdt_term())

    assert %{snapshots: [%Snapshot{tag: "2026-11-12.1"}]} = Values.from_term(blob)
  end

  test "what names nothing of MDT's decodes as it is" do
    term = %{text: "MDTClient and mdt stay text", at: ~U[2026-11-18 10:00:00Z]}

    assert FormerName.binary_to_term(:erlang.term_to_binary(term)) == term
  end

  test "a grant of MDT's tools gets MWT's id" do
    saved = Map.from_struct(%Grant{id: "mdt-change", name: "Change", kind: :mwt, tools: :change})

    assert %Grant{id: "mwt-change"} = Grant.upgrade(saved)
    assert %Grant{id: "mdt-notes"} = Grant.upgrade(%{saved | id: "mdt-notes"})
  end
end
