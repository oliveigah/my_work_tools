defmodule MWTClient.Sandbox.ProposalTest do
  @moduledoc """
  What an agent proposes (`mwt propose`), as the form's fields of what it
  makes: a resource, a grant over one, or an action. A preset's fields
  first, the options' over them, `--set`'s over both; nothing of a value,
  a start setting or an approval mode comes from it.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Credential, Grant, Network, Proposal}

  doctest Proposal

  @github %{
    id: "github",
    makes: :credential,
    fields: %{"adapter" => "github", "git" => "true", "prefix" => "ghp_", "env" => "GH_TOKEN"}
  }

  @known %{
    grants: [%Grant{id: "gh-read", name: "GitHub, read-only", kind: :token, credential: "github"}],
    credentials: [
      %Credential{id: "github", name: "GitHub", request_headers: "Accept: x"},
      %Credential{id: "app", name: "My App"}
    ],
    networks: [%Network{id: "internet", name: "Internet"}, %Network{id: "lan", name: "LAN"}]
  }

  test "what the word after propose names: a new resource, a grant over one, or an action's" do
    assert {:new, :credential} = Proposal.target("credential", nil, @known)
    assert {:new, :network} = Proposal.target("network", nil, @known)
    assert {:error, :token_split} = Proposal.target("token", nil, @known)

    # A grant over a credential or a network, by its id or name.
    assert {:grant, {:credential, "app"}, %{name: "My App"}} =
             Proposal.target("grant", "my app", @known)

    assert {:grant, {:network, "lan"}, _over} = Proposal.target("grant", "LAN", @known)
    assert {:error, :no_over} = Proposal.target("grant", nil, @known)
    assert {:error, {:unknown_resource, "nope"}} = Proposal.target("grant", "nope", @known)
    assert {:error, {:no_grants, "Host commands"}} = Proposal.target("grant", "machine", @known)

    # Your machine, by its word or the id Ask to run commands had.
    for word <- ["machine", "commands", "any-command"] do
      assert {:over, :machine, %{name: "Host commands"}} = Proposal.target(word, nil, @known)
    end

    # A credential, by its id or name, or by a token grant over it.
    for word <- ["github", "GitHub", "gh-read", "github, READ-ONLY"] do
      assert {:over, {:credential, "github"}, %{name: "GitHub", request_headers: "Accept: x"}} =
               Proposal.target(word, nil, @known)
    end

    assert {:error, {:no_actions, "LAN"}} = Proposal.target("lan", nil, @known)
    assert {:error, :unknown_grant} = Proposal.target("Ask to run commands", nil, @known)
  end

  test "a credential starts from its preset; options, then --set, override it" do
    {:ok, attrs} =
      Proposal.attrs(
        {:new, :credential},
        %{
          name: " GitHub, read-only ",
          purpose: "Read",
          env: ["GITHUB_TOKEN"],
          set: %{"prefix" => "github_pat_", "env" => "GH_TOKEN, GITHUB_TOKEN"}
        },
        @github
      )

    assert attrs["kind"] == "token" and attrs["preset"] == "github"
    assert attrs["name"] == "GitHub, read-only"
    # --set over the option, the option over the preset.
    assert attrs["env"] == "GH_TOKEN, GITHUB_TOKEN"
    assert attrs["prefix"] == "github_pat_"
    # What the agent left out stays the preset's.
    assert attrs["git"] == "true" and attrs["adapter"] == "github"
    assert attrs["source"] == "stored"
    refute Map.has_key?(attrs, "value")
    refute Map.has_key?(attrs, "start")
  end

  test "a mint command makes it minted, given as an option or set as a field" do
    for ask <- [
          %{mint: "gcloud auth print-access-token"},
          %{set: %{"mint" => "gcloud auth print-access-token"}}
        ] do
      {:ok, attrs} =
        Proposal.attrs({:new, :credential}, Map.merge(%{name: "G", purpose: "p"}, ask), nil)

      assert attrs["source"] == "minted"
      assert attrs["mint"] == "gcloud auth print-access-token"
      assert attrs["prefix"] == "mwt_"
    end
  end

  test "a metadata project or account asks for the metadata server; neither leaves the preset's" do
    {:ok, asked} =
      Proposal.attrs(
        {:new, :credential},
        %{name: "G", purpose: "p", metadata_project: " my-project ", metadata_account: ""},
        nil
      )

    assert %{"present_metadata" => "true", "present_project" => "my-project"} = asked
    refute Map.has_key?(asked, "present_email")

    # An account alone still asks, so the missing project is refused, not
    # dropped.
    {:ok, account_only} =
      Proposal.attrs(
        {:new, :credential},
        %{name: "G", purpose: "p", metadata_account: "a@b.c"},
        nil
      )

    assert %{"present_metadata" => "true", "present_email" => "a@b.c"} = account_only

    preset = %{
      id: "mine",
      makes: :credential,
      fields: %{"present_metadata" => "true", "present_project" => "theirs"}
    }

    {:ok, kept} = Proposal.attrs({:new, :credential}, %{name: "G", purpose: "p"}, preset)
    assert %{"present_metadata" => "true", "present_project" => "theirs"} = kept
  end

  test "a login file is asked for by name, or by the header its ID token travels in" do
    {:ok, asked} =
      Proposal.attrs({:new, :credential}, %{name: "G", purpose: "p", login_file: true}, nil)

    assert asked["present_login"] == "true"

    {:ok, header} =
      Proposal.attrs(
        {:new, :credential},
        %{name: "G", purpose: "p", id_token_header: "X-Id"},
        nil
      )

    assert %{"present_login" => "true", "present_id_header" => "X-Id"} = header

    {:ok, neither} = Proposal.attrs({:new, :credential}, %{name: "G", purpose: "p"}, nil)
    refute Map.has_key?(neither, "present_login")
  end

  test "a grant over a credential: its hosts, headers and accounts, over the credential it names" do
    {:ok, attrs} =
      Proposal.attrs(
        {:grant, {:credential, "gcp"}, %{name: "GCP"}},
        %{
          name: "IAP",
          purpose: "p",
          hosts: ["svc.example.com"],
          carriers: ["X-Token"],
          signs_as: ["a@p.iam.gserviceaccount.com", "b@p.iam.gserviceaccount.com"],
          set: %{"attributes" => "http.method = GET"}
        },
        nil
      )

    assert %{"kind" => "token", "credential" => "gcp", "hosts" => "svc.example.com"} = attrs
    assert attrs["carriers"] == "X-Token"
    assert attrs["signs_as"] == "a@p.iam.gserviceaccount.com, b@p.iam.gserviceaccount.com"
    assert attrs["attributes"] == "http.method = GET"

    # How its value is made is the credential's: a grant has no such field.
    assert {:error, "--mint isn't for a grant over a credential" <> _} =
             Proposal.attrs(
               {:grant, {:credential, "gcp"}, %{name: "GCP"}},
               %{name: "x", purpose: "p", mint: "gcloud auth print-access-token"},
               nil
             )

    assert {:error, "A grant over a credential has no field mint" <> _} =
             Proposal.attrs(
               {:grant, {:credential, "gcp"}, %{name: "GCP"}},
               %{name: "x", purpose: "p", set: %{"mint" => "x"}},
               nil
             )
  end

  test "a network lists one destination a line, with its DNS server and way out" do
    {:ok, attrs} =
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

    {:ok, part} =
      Proposal.attrs(
        {:grant, {:network, "lan"}, %{}},
        %{name: "N", purpose: "p", destinations: ["a:1"]},
        nil
      )

    assert %{"kind" => "network", "network" => "lan", "destinations" => "a:1"} = part
  end

  test "a saved command starts confined, as one you add does, and nothing sets that" do
    {:over, :machine, over} = Proposal.target("machine", nil, %{})

    {:ok, attrs} =
      Proposal.attrs({:over, :machine, over}, %{name: "n", purpose: "p", script: "ls"}, nil)

    assert %{"kind" => "command", "preset" => "saved_command", "confined" => "true"} = attrs

    assert {:error, "confined is yours to set, as you review it."} =
             Proposal.attrs(
               {:over, :machine, over},
               %{name: "n", purpose: "p", script: "ls", set: %{"confined" => "false"}},
               nil
             )
  end

  test "a request action starts from its credential's headers when it names none" do
    over = {:over, {:credential, "github"}, %{name: "github", request_headers: "Accept: x"}}
    {:ok, attrs} = Proposal.attrs(over, %{name: "n", purpose: "p", url: "https://a/b"}, nil)

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

    assert Proposal.refusal(%{signs_as: "An email."}) == "--sign-as: An email."
    assert Proposal.refusal(%{prefix: "Short."}) == "--set prefix: Short."
  end
end
