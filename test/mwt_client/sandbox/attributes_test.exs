defmodule MWTClient.Sandbox.AttributesTest do
  @moduledoc """
  Grants narrowed by what the protocol frames or a request names
  (`MWTClient.Sandbox.Attributes`): a grant covers a use only where each
  attribute it names matches, and grants only give; what MWT couldn't read
  counts against the use: only a grant that would ask about it covers it,
  unless its *Covers requests MWT can't read* is off. And *Allow similar,
  any id*, an allowance whose path's ids are wildcards.
  """
  use MWTClient.PolicyCase, async: true

  alias MWTClient.Sandbox.{Attributes, Credential}

  doctest MWTClient.Sandbox.Attributes
  doctest MWTClient.Sandbox.Allowance, only: [widen: 1]

  @p "ghp_mwt_attributes_0123456789"

  defp github(id, state, attributes, extra \\ %{}) do
    grant =
      struct(
        %Grant{
          id: id,
          name: id,
          kind: :token,
          credential: "github",
          placeholder: @p,
          hosts: ["api.github.com"],
          attributes: attributes
        },
        extra
      )

    case state do
      :auto -> %{grant | state: :on, allowances: [allowance(:all, nil)]}
      :ask -> %{grant | state: :on}
      :off -> Grant.put_down(grant)
    end
  end

  defp req(method, path, body \\ "") do
    %{
      host: "api.github.com",
      method: method,
      path: path,
      headers: [{"authorization", "token " <> @p}],
      body: body
    }
  end

  defp decide(grants, request) do
    {grants, _} = Credential.migrate(grants, [])
    Policy.decide(snapshot([internet_on() | grants]), {:request, request}, @now)
  end

  test "a grant over a repository gives only that one, and the most permissive on counts" do
    klife = github("klife", :auto, %{"github.repository" => ["oliveigah/klife"]})
    issues = req("GET", "/repos/oliveigah/klife/issues")
    other = req("GET", "/repos/oliveigah/other/issues")

    assert {:allow, %{id: "klife"}, _, _} = decide([github("github", :off, %{}), klife], issues)

    # The rest only a grant over the whole credential gives: refused,
    # naming it, while it is off.
    assert {:refuse, {:grant_off, %{id: "github"}}} =
             decide([github("github", :off, %{}), klife], other)

    # Off, the narrow one has no say; asking, the wide one auto-approving
    # gives what it covers.
    assert {:allow, %{id: "github"}, _, _} =
             decide([github("github", :auto, %{}), %{klife | state: :off}], issues)

    assert {:allow, %{id: "github"}, _, _} =
             decide([github("github", :auto, %{}), %{klife | allowances: []}], issues)
  end

  test "what MWT can't read is covered only by a grant that asks, unless it says otherwise" do
    klife = github("klife", :ask, %{"github.repository" => ["oliveigah/klife"]})
    query = Jason.encode!(%{"query" => ~s|query { node(id: "MDEwOlJlcG9zaXRvcnk=") { id } }|})
    graphql = req("POST", "/graphql", query)

    # A GraphQL query names its repository where MWT doesn't read it.
    assert {:ask, %{id: "klife"}, _} = decide([klife], graphql)

    # Auto-approving, it would let through what it can't see: it doesn't
    # cover it.
    auto = %{klife | allowances: [allowance(:all, nil)]}
    assert {:refuse, {:uncovered, %{id: "klife"}}} = decide([auto], graphql)

    lenient = %{klife | covers_unread: false}
    assert {:refuse, {:uncovered, %{id: "klife"}}} = decide([lenient], graphql)

    assert {:allow, %{id: "github"}, _, _} =
             decide([github("github", :auto, %{}), lenient], graphql)
  end

  test "a grant only for reading covers no write: none over the credential covers it" do
    reads = github("reads", :auto, %{"http.method" => ["GET", "HEAD"]})

    assert {:allow, _, _, _} = decide([reads], req("GET", "/user"))

    assert {:refuse, {:uncovered, %{id: "reads"}}} =
             decide([reads], req("DELETE", "/repos/o/r"))
  end

  test "reads git's direction and gRPC's method from the path" do
    assert %{"git.direction" => "push"} =
             Attributes.of(%{
               method: "POST",
               host: "github.com",
               path: "/o/r.git/git-receive-pack",
               headers: [],
               body: ""
             })

    assert %{"grpc.method" => "google.storage.v2.Storage/ReadObject"} =
             Attributes.of(%{
               method: "POST",
               host: "storage.googleapis.com",
               path: "/google.storage.v2.Storage/ReadObject",
               headers: [{"content-type", "application/grpc"}],
               body: ""
             })
  end

  test "an allowance for any id covers every id of the endpoint, and nothing else" do
    wild = allowance("GET api.github.com/repos/o/r/pulls/* · in authorization", nil)

    assert MWTClient.Sandbox.Allowance.covers?(
             wild,
             "GET api.github.com/repos/o/r/pulls/7 · in authorization",
             @now
           )

    refute MWTClient.Sandbox.Allowance.covers?(
             wild,
             "GET api.github.com/repos/o/r/pulls/7/files · in authorization",
             @now
           )

    refute MWTClient.Sandbox.Allowance.covers?(
             wild,
             "POST api.github.com/repos/o/r/pulls/7 · in authorization",
             @now
           )
  end

  test "parses a form's lines, and refuses a name it doesn't know" do
    assert {:ok, %{"http.path" => ["/repos/*/pulls/**"]}} =
             Attributes.parse("http.path = /repos/*/pulls/**")

    assert {:error, _} = Attributes.parse("sql.table = users")
  end
end
