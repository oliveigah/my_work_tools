defmodule MWTClient.Sandbox.ProposalTest do
  @moduledoc """
  What an agent proposes (`mwt propose`), as the add form's fields: only
  what it gave overrides a preset, and nothing of a value, a start
  setting or an approval mode comes from it. An action goes over its
  resource: a request action over a credential, a saved command over your
  machine.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Grant, Proposal}

  doctest Proposal

  @github %{
    id: "github",
    kind: :token,
    fields: %{"hosts" => "api.github.com, github.com", "git" => "true", "prefix" => "ghp_"}
  }

  test "a new grant's name is a type; anything else names the resource an action goes over" do
    read = %Grant{
      id: "gh-read",
      name: "GitHub, read-only",
      kind: :token,
      credential: "github",
      request_headers: "Accept: x"
    }

    lan = %Grant{id: "lan", name: "LAN", kind: :network}
    grants = [read, lan]

    assert {:new, :token} = Proposal.target("token", grants)

    # Your machine, by its word or the id Ask to run commands had.
    for word <- ["machine", "commands", "any-command"] do
      assert {:over, :machine, %{name: "Your machine"}} = Proposal.target(word, grants)
    end

    # A credential, by its id or a token grant over it, by id or by name.
    for word <- ["github", "gh-read", "github, READ-ONLY"] do
      assert {:over, {:credential, "github"}, %{name: "github", request_headers: "Accept: x"}} =
               Proposal.target(word, grants)
    end

    assert {:error, {:no_actions, "LAN"}} = Proposal.target("lan", grants)
    assert {:error, :unknown_grant} = Proposal.target("Ask to run commands", grants)
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

  test "a mint command makes it minted" do
    attrs =
      Proposal.attrs(
        {:new, :token},
        %{name: "G", purpose: "p", mint: "gcloud auth print-access-token"},
        nil
      )

    assert attrs["source"] == "minted"
    assert attrs["mint"] == "gcloud auth print-access-token"
    assert attrs["prefix"] == "mwt_"
  end

  test "a metadata project or account asks for the metadata server; neither leaves the preset's" do
    asked =
      Proposal.attrs(
        {:new, :token},
        %{name: "G", purpose: "p", metadata_project: " my-project ", metadata_account: ""},
        nil
      )

    assert %{"present_metadata" => "true", "present_project" => "my-project"} = asked
    refute Map.has_key?(asked, "present_email")

    # An account alone still asks, so the missing project is refused, not
    # dropped.
    account_only =
      Proposal.attrs({:new, :token}, %{name: "G", purpose: "p", metadata_account: "a@b.c"}, nil)

    assert %{"present_metadata" => "true", "present_email" => "a@b.c"} = account_only

    preset = %{
      id: "mine",
      kind: :token,
      fields: %{"present_metadata" => "true", "present_project" => "theirs"}
    }

    kept = Proposal.attrs({:new, :token}, %{name: "G", purpose: "p"}, preset)
    assert %{"present_metadata" => "true", "present_project" => "theirs"} = kept
  end

  test "the accounts it signs as, and how long a minted value is kept, come as the form takes them" do
    attrs =
      Proposal.attrs(
        {:new, :token},
        %{
          name: "IAP",
          purpose: "p",
          mint: "gcloud auth print-access-token",
          keep_minutes: 4,
          signs_as: ["a@p.iam.gserviceaccount.com", "b@p.iam.gserviceaccount.com"]
        },
        nil
      )

    assert attrs["keep_minutes"] == "4"
    assert attrs["signs_as"] == "a@p.iam.gserviceaccount.com, b@p.iam.gserviceaccount.com"
    assert Proposal.refusal(%{signs_as: "An email."}) == "--sign-as: An email."
  end

  test "a login file is asked for by name, or by the header its ID token travels in" do
    asked = Proposal.attrs({:new, :token}, %{name: "G", purpose: "p", login_file: true}, nil)
    assert asked["present_login"] == "true"

    header =
      Proposal.attrs({:new, :token}, %{name: "G", purpose: "p", id_token_header: "X-Id"}, nil)

    assert %{"present_login" => "true", "present_id_header" => "X-Id"} = header

    refute Map.has_key?(
             Proposal.attrs({:new, :token}, %{name: "G", purpose: "p"}, nil),
             "present_login"
           )
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

  test "a saved command starts confined, as one you add does" do
    {:over, :machine, over} = Proposal.target("machine", [])
    attrs = Proposal.attrs({:over, :machine, over}, %{name: "n", purpose: "p", script: "ls"}, nil)

    assert %{"kind" => "command", "preset" => "saved_command", "confined" => "true"} = attrs
  end

  test "a request action starts from its credential's headers when it names none" do
    over = {:over, {:credential, "github"}, %{name: "github", request_headers: "Accept: x"}}
    attrs = Proposal.attrs(over, %{name: "n", purpose: "p", url: "https://a/b"}, nil)

    assert %{
             "kind" => "request",
             "credential" => "github",
             "method" => "GET",
             "headers" => "Accept: x"
           } =
             attrs
  end

  test "a refusal names the option each message comes from, in the order the help gives them" do
    assert Proposal.refusal(%{hosts: "List a host.", name: "Name it."}) ==
             "--name: Name it. --host: List a host."

    assert Proposal.refusal(%{present_email: "An email.", present_project: "A project."}) ==
             "--metadata-project: A project. --metadata-account: An email."
  end
end
