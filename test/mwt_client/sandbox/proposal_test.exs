defmodule MWTClient.Sandbox.ProposalTest do
  @moduledoc """
  What an agent proposes (`mwt propose`), as the add form's fields: only
  what it gave overrides a preset, and nothing of a value, a check, a
  start setting or an approval mode comes from it.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Grant, Proposal}

  doctest Proposal

  @github %{
    id: "github",
    kind: :token,
    fields: %{"hosts" => "api.github.com, github.com", "git" => "true", "prefix" => "ghp_"}
  }

  test "a new grant's name is a type; anything else names the grant a subgrant goes under" do
    commands = Grant.ask_to_run()
    lan = %Grant{id: "lan", name: "LAN", kind: :network}

    assert {:new, :token} = Proposal.target("token", [commands])
    assert {:under, ^commands} = Proposal.target("Ask to run commands", [commands])
    assert {:error, {:no_subgrants, "LAN"}} = Proposal.target("lan", [lan])
  end

  test "a token grant starts from its preset, the agent's fields overriding it" do
    attrs =
      Proposal.attrs(
        {:new, :token},
        %{name: " GitHub, read-only ", purpose: "Read", hosts: ["api.github.com"], git: false},
        @github
      )

    assert attrs["kind"] == "token" and attrs["preset"] == "github"
    assert attrs["name"] == "GitHub, read-only"
    assert attrs["hosts"] == "api.github.com"
    # What the agent left out stays the preset's.
    assert attrs["git"] == "true" and attrs["prefix"] == "ghp_"
    assert attrs["source"] == "stored"
    refute Map.has_key?(attrs, "value")
    refute Map.has_key?(attrs, "start")
  end

  test "a mint command makes it minted; only for its subgrants keeps it out of the VM" do
    attrs =
      Proposal.attrs(
        {:new, :token},
        %{name: "G", purpose: "p", mint: "gcloud auth print-access-token", subgrants_only: true},
        nil
      )

    assert attrs["source"] == "minted"
    assert attrs["mint"] == "gcloud auth print-access-token"
    assert attrs["reach"] == "subgrants"
    assert attrs["prefix"] == "mwt_"
  end

  test "a network grant lists one destination a line, with its DNS server and way out" do
    attrs =
      Proposal.attrs(
        {:new, :network},
        %{
          name: "N",
          purpose: "p",
          destinations: ["a:1", "b:2"],
          resolver: "10.8.0.1",
          anchor: "wg0"
        },
        nil
      )

    assert %{"destinations" => "a:1\nb:2", "resolver" => "10.8.0.1", "anchor" => "wg0"} = attrs
  end

  test "a command subgrant starts confined, as one you add does" do
    attrs =
      Proposal.attrs({:under, Grant.ask_to_run()}, %{name: "n", purpose: "p", script: "ls"}, nil)

    assert %{"kind" => "command", "preset" => "saved_command", "confined" => "true"} = attrs
  end

  test "a request subgrant starts from its grant's headers when it names none" do
    parent = %Grant{id: "github", name: "GitHub", kind: :token, request_headers: "Accept: x"}
    attrs = Proposal.attrs({:under, parent}, %{name: "n", purpose: "p", url: "https://a/b"}, nil)

    assert %{
             "kind" => "request",
             "parent" => "github",
             "method" => "GET",
             "headers" => "Accept: x"
           } =
             attrs
  end

  test "a refusal names the option each message comes from, in the order the help gives them" do
    assert Proposal.refusal(%{hosts: "List a host.", name: "Name it."}) ==
             "--name: Name it. --host: List a host."
  end
end
