defmodule MWTClient.Sandbox.FirewallReleaseTest do
  @moduledoc """
  Releasing an isolation the firewall made: what the incident was counted
  on starts over, in the watch and in the server, so the next connection
  or lookup isn't judged on what you just reviewed; and trusting adds the
  exact name the finding saw, as a list entry.
  """
  use ExUnit.Case, async: true

  # Isolating logs a warning.
  @moduletag :capture_log

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Gate

  @mib 1024 * 1024
  @public {93, 184, 216, 34}

  setup do
    MWTClient.VaultHelpers.unlocked_identity("firewall-release")
  end

  defp incident(username), do: Sandbox.firewall(username).firewall.isolated
  defp trusted(username), do: Sandbox.firewall(username).firewall.trusted

  test "released, a large upload's domain counts from zero again", %{username: username} do
    assert :cut = Gate.upload(username, "files.example", 443, 5 * @mib, 0)
    assert %{rule: :large_upload, host: "files.example"} = incident(username)

    :ok = Sandbox.firewall_release(username, false)

    # A new connection under the same domain, and what it sends, are
    # judged on their own bytes.
    assert {kind, _watch} = Gate.route(username, @public, 443, "cdn.files.example")
    assert kind in [:tunnel, :intercept]
    assert :ok = Gate.upload(username, "cdn.files.example", 443, 3 * @mib, 0)
    assert incident(username) == nil

    # Nothing was trusted for it: the domain is still watched.
    refute "files.example" in trusted(username)
    assert :cut = Gate.upload(username, "cdn.files.example", 443, 2 * @mib, 0)
    assert %{rule: :large_upload} = incident(username)
  end

  test "released, names under a domain count from zero again", %{username: username} do
    for i <- 1..41, do: Gate.lookup(username, "n#{i}.names.example")
    assert %{rule: :dns_tunnel, host: "names.example"} = incident(username)

    :ok = Sandbox.firewall_release(username, false)

    for i <- 1..10, do: assert(:ok = Gate.lookup(username, "w#{i}.names.example"))
    assert incident(username) == nil
  end

  test "released, what the server counts (reads of your notes) counts from zero again", %{
    username: username
  } do
    :ok = Sandbox.firewall_set(username, {:action, :bulk_reads, :isolate})
    caller = MWTClient.Sandbox.MwtTools.caller(username, %{agent: "codex", thread: "t"}, [])
    read = fn -> MWTClient.MCP.Tools.call("list_notes", %{}, caller) end

    for _read <- 1..100, do: read.()
    assert %{rule: :bulk_reads} = incident(username)

    :ok = Sandbox.firewall_release(username, false)
    for _read <- 1..10, do: read.()
    assert incident(username) == nil
  end

  test "trusting a model's API through a cloud trusts that name, not the cloud", %{
    username: username
  } do
    model = "us-east5-aiplatform.googleapis.com"

    # A long session's turns: its context up, a short answer back.
    for _turn <- 1..26, do: Gate.upload(username, model, 443, 160 * 1024, 6 * 1024)
    assert %{rule: :large_upload, host: ^model} = incident(username)

    :ok = Sandbox.firewall_release(username, true)
    assert model in trusted(username)
    refute "googleapis.com" in trusted(username)

    # The model's host is spared from now on; the rest of the cloud isn't.
    assert :ok = Gate.upload(username, model, 443, 50 * @mib, 0)
    assert incident(username) == nil
    assert :cut = Gate.upload(username, "storage.googleapis.com", 443, 5 * @mib, 0)
    assert %{rule: :large_upload, host: "storage.googleapis.com"} = incident(username)
  end

  test "a tunnel's destination is trusted by its name, and the list still saves", %{
    username: username
  } do
    :cut = Gate.found(username, {:value, "GitHub"}, "paste.example.net:80", :plaintext)
    assert %{rule: :real_value, host: "paste.example.net:80"} = incident(username)

    :ok = Sandbox.firewall_release(username, true)
    assert "paste.example.net" in trusted(username)
    refute "paste.example.net:80" in trusted(username)

    # The list as the editor shows it saves as it is.
    assert :ok =
             Sandbox.firewall_set(username, {:list, :trusted, Enum.join(trusted(username), "\n")})
  end
end
