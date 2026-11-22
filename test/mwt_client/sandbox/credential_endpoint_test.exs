defmodule MWTClient.Sandbox.CredentialEndpointTest do
  @moduledoc """
  A credential endpoint MWT answers itself (`CredentialEndpoint`), and the
  values it makes (`Made`): IAM Credentials' `signJwt` for a grant that
  signs as a service account. First what is pure, then the whole way: the
  VM asks to sign, MWT signs with the grant's real value and answers with a
  placeholder JWT, and that placeholder goes only to the host its `aud`
  names, as the real JWT.
  """
  use ExUnit.Case, async: true

  doctest MWTClient.Sandbox.CredentialEndpoint
  doctest MWTClient.Sandbox.Made

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{CredentialEndpoint, Gate, Grant, Made, SavedRequest, Secrets, Server}
  alias MWTClient.Vault.Store

  @account "sa@p.iam.gserviceaccount.com"
  @value "ya29.real_value_0123456789"

  @grant %Grant{
    id: "iap",
    name: "IAP",
    kind: :token,
    hosts: ["*.googleapis.com", "svc.example.com", "other.example.com"],
    signs_as: [@account]
  }

  defp sign_request(placeholder, claims, attrs \\ %{}) do
    body = Jason.encode!(%{payload: Jason.encode!(claims)})

    Map.merge(
      %{
        host: "iamcredentials.googleapis.com",
        method: "POST",
        path: "/v1/projects/-/serviceAccounts/#{URI.encode_www_form(@account)}:signJwt",
        headers: [
          {"authorization", "Bearer #{placeholder}"},
          {"content-type", "application/json"},
          {"content-length", Integer.to_string(byte_size(body))}
        ],
        body: body
      },
      attrs
    )
  end

  defp claims(now \\ System.os_time(:second)) do
    %{
      "iss" => @account,
      "sub" => @account,
      "aud" => "https://svc.example.com/*",
      "iat" => now,
      "exp" => now + 3_600
    }
  end

  # A JWT as Google signs one: base64url header and claims, and a signature
  # as long as an RS256 one.
  defp signed(claims) do
    header = %{"alg" => "RS256", "kid" => "k1", "typ" => "JWT"}

    [Jason.encode!(header), Jason.encode!(claims)]
    |> Enum.map(&Base.url_encode64(&1, padding: false))
    |> Enum.concat([String.duplicate("S", 342)])
    |> Enum.join(".")
  end

  describe "what is pure" do
    test "only a request to sign, for a grant that signs, is one MWT answers" do
      request = sign_request("p", claims())

      assert CredentialEndpoint.recognize(@grant, request) == {:sign_jwt, @account}
      assert CredentialEndpoint.recognize(%{@grant | signs_as: []}, request) == nil
      assert CredentialEndpoint.recognize(@grant, %{request | method: "GET"}) == nil

      other = %{request | path: "/v1/projects/-/serviceAccounts/#{@account}:generateAccessToken"}
      assert CredentialEndpoint.recognize(@grant, other) == nil
      assert CredentialEndpoint.recognize(@grant, %{request | host: "evil.example.com"}) == nil
    end

    test "it signs only as an account the grant names, for a host it lists, with no delegation" do
      check = &CredentialEndpoint.check(@grant, &1, CredentialEndpoint.recognize(@grant, &1))

      assert {:ok, %{account: @account, aud_host: "svc.example.com", payload: payload}} =
               check.(sign_request("p", claims()))

      assert Jason.decode!(payload) == claims()

      other_account = %{
        sign_request("p", claims())
        | path: "/v1/projects/-/serviceAccounts/root@p.iam.gserviceaccount.com:signJwt"
      }

      assert {:error, "mwt_not_a_signer", message} = check.(other_account)
      assert message =~ "may sign only as #{@account}"

      unlisted = Map.put(claims(), "aud", "https://elsewhere.example.com/*")
      assert {:error, "mwt_placeholder_blocked", _} = check.(sign_request("p", unlisted))

      assert {:error, "mwt_bad_request", _} =
               check.(sign_request("p", Map.delete(claims(), "aud")))

      delegated =
        Jason.encode!(%{payload: Jason.encode!(claims()), delegates: ["projects/-/x"]})

      assert {:error, "mwt_bad_request", _} =
               check.(
                 sign_request("p", claims(), %{
                   body: delegated,
                   headers: [{"content-length", "#{byte_size(delegated)}"}]
                 })
               )

      # Only what MWT read whole is signed.
      cut = sign_request("p", claims())
      cut = %{cut | headers: [{"content-length", "999999"}]}
      assert {:error, "mwt_bad_request", _} = check.(cut)
    end

    test "Google's signed JWT is kept; the VM gets its header and claims, never its signature" do
      now = DateTime.utc_now()

      {:ok, ask} =
        CredentialEndpoint.check(@grant, sign_request("p", claims()), {:sign_jwt, @account})

      jwt = signed(claims())
      output = Jason.encode!(%{keyId: "k1", signedJwt: jwt})

      assert {:ok, %Made{} = made, json} =
               CredentialEndpoint.answered(@grant, ask, %{status: 200, output: output}, now)

      assert %{"keyId" => "k1", "signedJwt" => placeholder} = Jason.decode!(json)
      assert placeholder == made.placeholder and made.value == jwt
      refute json =~ String.duplicate("S", 342)
      assert Made.claims(placeholder) == {:ok, claims()}
      assert Made.jwt_placeholders_in("Bearer " <> placeholder) == [placeholder]
      assert made.hosts == ["svc.example.com"] and made.carriers == ["authorization"]
      assert DateTime.to_unix(made.until) == claims()["exp"]

      # A refusal goes on as Google wrote it; any other answer doesn't.
      denied = ~s({"error": {"code": 403, "status": "PERMISSION_DENIED"}})

      assert {:error, 403, ^denied} =
               CredentialEndpoint.answered(@grant, ask, %{status: 403, output: denied}, now)

      assert {:error, 502, _} =
               CredentialEndpoint.answered(@grant, ask, %{status: 201, output: output}, now)

      assert {:error, 504, _} = CredentialEndpoint.answered(@grant, ask, %{timed_out: true}, now)
    end

    test "a refresh of a grant's login is answered with its placeholders; nothing else of the login" do
      login = %{
        @grant
        | placeholder: "ya29.mwt_placeholder",
          presents: %{login: %{refresh: "1//mwt_login", header: "x-id-token"}}
      }

      refresh = fn form ->
        body = URI.encode_query(form)

        %{
          host: "oauth2.googleapis.com",
          method: "POST",
          path: "/token",
          headers: [{"content-length", "#{byte_size(body)}"}],
          body: body
        }
      end

      ok = refresh.(%{"grant_type" => "refresh_token", "refresh_token" => "1//mwt_login"})
      assert CredentialEndpoint.recognize(login, ok) == :refresh
      assert CredentialEndpoint.recognize(@grant, ok) == nil
      assert {:ok, %{kind: :refresh}} = CredentialEndpoint.check(login, ok, :refresh)

      other_login = refresh.(%{"grant_type" => "refresh_token", "refresh_token" => "1//other"})

      assert {:error, "mwt_bad_request", _} =
               CredentialEndpoint.check(login, other_login, :refresh)

      code = refresh.(%{"grant_type" => "authorization_code", "code" => "x"})
      assert {:error, "mwt_bad_request", _} = CredentialEndpoint.check(login, code, :refresh)

      # The ID token's placeholder keeps who issued it, for whom, when, and
      # the two claims a client reads of the person: nothing else.
      now = DateTime.utc_now()
      exp = DateTime.to_unix(now) + 3_600

      id_claims = %{
        "iss" => "https://accounts.google.com",
        "aud" => "32555940559.apps.googleusercontent.com",
        "iat" => exp - 3_600,
        "exp" => exp,
        "email" => "person@example.com",
        "hd" => "example.com",
        "sub" => "1234567890",
        "name" => "A Person",
        "at_hash" => "abc"
      }

      {made, json} = CredentialEndpoint.refreshed(login, signed(id_claims), 240, now)

      assert %{"access_token" => "ya29.mwt_placeholder", "expires_in" => 240} =
               answer = Jason.decode!(json)

      assert answer["id_token"] == made.placeholder
      assert {:ok, shown} = Made.claims(made.placeholder)
      assert shown == Map.take(id_claims, ~w(iss aud iat exp email hd))
      assert made.source == :id_token and made.value == nil
      assert made.carriers == ["x-id-token"] and made.hosts == login.hosts

      # A mint that gives no ID token: a plain refresh.
      {nil, plain} = CredentialEndpoint.refreshed(login, nil, 240, now)
      refute Map.has_key?(Jason.decode!(plain), "id_token")
    end

    test "a made value is covered while unexpired and its grant still signs as its account for its host" do
      now = DateTime.utc_now()

      made = %Made{
        placeholder: "x.y.z",
        grant_id: "iap",
        name: "IAP's JWT",
        account: @account,
        hosts: ["svc.example.com"],
        carriers: ["authorization"],
        until: DateTime.add(now, 60, :second)
      }

      assert Made.covered?(made, [@grant], now)
      refute Made.covered?(made, [@grant], DateTime.add(now, 61, :second))
      refute Made.covered?(made, [%{@grant | signs_as: []}], now)
      refute Made.covered?(made, [%{@grant | hosts: ["*.googleapis.com"]}], now)
      refute Made.covered?(made, [], now)
    end
  end

  describe "the whole way" do
    setup do
      %{username: username} = identity = MWTClient.VaultHelpers.unlocked_identity("signing")

      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "IAP",
          "purpose" => "The internal service behind IAP",
          "hosts" => "*.googleapis.com, svc.example.com, other.example.com",
          "signs_as" => @account,
          "prefix" => "ya29.mwt",
          "source" => "stored",
          "value" => @value
        })

      {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)

      # Nothing reaches Google: each test says what answers instead.
      Req.Test.stub(SavedRequest, &Plug.Conn.send_resp(&1, 500, "no stub"))
      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, username))
      Map.put(identity, :grant, grant)
    end

    defp authorize(username, request), do: Server.call(username, {:authorize, request})

    # Has MWT sign `claims` for the grant, Google answering with `jwt`;
    # the placeholder the VM gets back.
    defp sign!(username, grant, jwt) do
      Req.Test.stub(SavedRequest, &Req.Test.json(&1, %{keyId: "k1", signedJwt: jwt}))
      assert {:answer, 200, json} = authorize(username, sign_request(grant.placeholder, claims()))
      Jason.decode!(json)["signedJwt"]
    end

    defp to_service(placeholder, host \\ "svc.example.com") do
      %{
        host: host,
        method: "GET",
        path: "/api/things",
        headers: [{"authorization", "Bearer #{placeholder}"}],
        body: ""
      }
    end

    test "MWT signs with the grant's value; the real JWT goes in its placeholder's place",
         %{username: username, grant: grant} do
      test = self()
      jwt = signed(claims())

      Req.Test.stub(SavedRequest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          test,
          {:signed, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), body}
        )

        Req.Test.json(conn, %{keyId: "k1", signedJwt: jwt})
      end)

      assert {:answer, 200, json} = authorize(username, sign_request(grant.placeholder, claims()))

      # The very request the tool makes, with the real token.
      assert_receive {:signed, path, ["Bearer " <> @value], body}
      assert path == "/v1/projects/-/serviceAccounts/sa%40p.iam.gserviceaccount.com:signJwt"
      assert Jason.decode!(Jason.decode!(body)["payload"]) == claims()

      %{"signedJwt" => placeholder} = Jason.decode!(json)
      refute placeholder == jwt
      refute inspect(Sandbox.snapshot(username)) =~ jwt

      # At once, the proxy's own view knows it: the real JWT goes in its
      # place, and the answer is looked through for it.
      assert {:forward, headers, scan} = Gate.authorize(username, to_service(placeholder))
      assert {"authorization", "Bearer " <> jwt} in headers
      assert [{_label, ^placeholder}] = Map.to_list(scan.placeholders)
      assert {:value, _name} = Secrets.find(scan.echo, "seen " <> jwt)
    end

    test "anywhere but its aud host, a host the grant lists included, it is a placeholder moved",
         %{username: username, grant: grant} do
      placeholder = sign!(username, grant, signed(claims()))

      assert {:deny, 403, refused} =
               Gate.authorize(username, to_service(placeholder, "other.example.com"))

      assert refused =~ "mwt_placeholder_blocked"

      # As for any grant's placeholder, the firewall isolates the VM.
      assert {:deny, 403, isolated} = Gate.authorize(username, to_service(placeholder))
      assert isolated =~ "mwt_isolated"
    end

    test "the real JWT in what the VM sends is a credential it should never have had",
         %{username: username, grant: grant} do
      jwt = signed(claims())
      _placeholder = sign!(username, grant, jwt)

      assert {:deny, 403, blocked} = Gate.authorize(username, to_service(jwt))
      assert blocked =~ "mwt_value_blocked"
    end

    test "asking each time, the card waits; allowed, MWT signs and answers",
         %{username: username} do
      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "IAP, asking",
          "purpose" => "The internal service behind IAP",
          "hosts" => "*.googleapis.com, svc.example.com",
          "signs_as" => @account,
          "source" => "stored",
          "value" => "ya29.asking_value_0123456789"
        })

      {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :ask)
      Req.Test.stub(SavedRequest, &Req.Test.json(&1, %{keyId: "k1", signedJwt: signed(claims())}))

      asking =
        Task.async(fn ->
          Server.call(
            username,
            {:authorize, sign_request(grant.placeholder, claims())},
            :infinity
          )
        end)

      approval =
        Enum.find_value(1..100, fn _ ->
          case Sandbox.snapshot(username).waiting do
            [approval | _] -> approval
            [] -> Process.sleep(10) && nil
          end
        end)

      assert approval.kind == :request and approval.host == "iamcredentials.googleapis.com"
      :ok = Sandbox.decide(username, approval.id, :allow_once)

      assert {:answer, 200, json} = Task.await(asking)
      assert [_placeholder] = Made.jwt_placeholders_in(json)
    end

    test "one MWT no longer holds is refused, saying to sign again", %{username: username} do
      stale = Made.jwt_placeholder(signed(claims()))

      request = %{
        host: "svc.example.com",
        method: "GET",
        path: "/",
        headers: [{"authorization", "Bearer #{stale}"}],
        body: ""
      }

      assert {:deny, 403, json} = Gate.authorize(username, request)
      assert json =~ "mwt_placeholder_expired"
    end

    test "what can't be signed is refused before anything goes out, and Google's refusal comes back",
         %{username: username, grant: grant} do
      test = self()

      Req.Test.stub(SavedRequest, fn conn ->
        send(test, :called)
        Plug.Conn.send_resp(conn, 403, ~s({"error": {"status": "PERMISSION_DENIED"}}))
      end)

      unlisted = Map.put(claims(), "aud", "https://elsewhere.example.com/*")

      assert {:deny, 403, json} = authorize(username, sign_request(grant.placeholder, unlisted))
      assert json =~ "mwt_placeholder_blocked"
      refute_received :called

      assert {:answer, 403, denied} =
               authorize(username, sign_request(grant.placeholder, claims()))

      assert denied =~ "PERMISSION_DENIED"
      assert_receive :called
    end

    # A grant whose login file MWT refreshes; its mint prints a value and
    # an ID token, counting each run so a fresh one shows.
    defp login_grant(username, dir) do
      count = Path.join(dir, "count")

      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "CLI",
          "purpose" => "The internal CLI",
          "hosts" => "*.googleapis.com, svc.example.com",
          "source" => "minted",
          "keep_minutes" => "4",
          "present_login" => "true",
          "present_id_header" => "X-Id-Token",
          "mint" =>
            ~s[echo x >> '#{count}'; n=$(wc -l < '#{count}' | tr -d ' '); printf '{"value": "ya29.minted-%s", "id_token": "%s", "expires_in": 3600}' "$n" "$(cat '#{dir}/id-'"$n")"]
        })

      {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)
      grant
    end

    defp refresh(grant) do
      body =
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "client_id" => "32555940559.apps.googleusercontent.com",
          "client_secret" => "mwt-not-a-secret",
          "refresh_token" => MWTClient.Sandbox.Grant.login_placeholder(grant)
        })

      %{
        host: "oauth2.googleapis.com",
        method: "POST",
        path: "/token",
        headers: [
          {"content-type", "application/x-www-form-urlencoded"},
          {"content-length", "#{byte_size(body)}"}
        ],
        body: body
      }
    end

    defp id_token(n) do
      now = System.os_time(:second)

      signed(%{
        "iss" => "https://accounts.google.com",
        "aud" => "32555940559.apps.googleusercontent.com",
        "email" => "person@example.com",
        "hd" => "example.com",
        "sub" => "secret-subject-#{n}",
        "iat" => now,
        "exp" => now + 3_600
      })
    end

    @tag :tmp_dir
    test "a refresh of the login is answered from the mint; the ID token goes in its own header, fresh",
         %{username: username, tmp_dir: dir} do
      for n <- 1..2, do: File.write!(Path.join(dir, "id-#{n}"), id_token(n))
      grant = login_grant(username, dir)

      # Through the proxy's own view: the login's placeholder makes the
      # refresh the grant's, and MWT answers it.
      assert {:answer, 200, json} = Gate.authorize(username, refresh(grant))

      %{"access_token" => access, "expires_in" => expires_in, "id_token" => id_placeholder} =
        Jason.decode!(json)

      assert access == grant.placeholder
      assert expires_in in 230..240
      refute json =~ "secret-subject"

      assert {:ok, %{"email" => "person@example.com", "hd" => "example.com"}} =
               Made.claims(id_placeholder)

      to_service = %{
        host: "svc.example.com",
        method: "GET",
        path: "/api",
        headers: [
          {"authorization", "Bearer #{access}"},
          {"x-id-token", id_placeholder}
        ],
        body: ""
      }

      # The token and the ID token the same mint gave.
      assert {:forward, headers, scan} = Gate.authorize(username, to_service)
      assert {"authorization", "Bearer ya29.minted-1"} in headers
      assert {"x-id-token", File.read!(Path.join(dir, "id-1"))} in headers
      assert map_size(scan.placeholders) == 2

      # Once the kept one is too old, the same placeholder brings a fresh
      # one, whenever the tool refreshed.
      server = Store.whereis(Server, username)

      :sys.replace_state(server, fn state ->
        old = System.monotonic_time(:millisecond) - 1
        %{state | minted: Map.new(state.minted, fn {k, {v, _}} -> {k, {v, old}} end)}
      end)

      assert {:forward, headers, _scan} = Gate.authorize(username, to_service)
      assert {"x-id-token", File.read!(Path.join(dir, "id-2"))} in headers

      # Only in its own header.
      misplaced = %{to_service | headers: [{"authorization", "Bearer #{id_placeholder}"}]}
      assert {:deny, 403, refused} = Gate.authorize(username, misplaced)
      assert refused =~ "mwt_not_a_carrier"
    end

    @tag :tmp_dir
    test "the login placeholder anywhere but a refresh is moved where it does not go",
         %{username: username, tmp_dir: dir} do
      File.write!(Path.join(dir, "id-1"), id_token(1))
      grant = login_grant(username, dir)
      login = MWTClient.Sandbox.Grant.login_placeholder(grant)

      elsewhere = %{
        host: "svc.example.com",
        method: "POST",
        path: "/",
        headers: [{"content-length", "#{byte_size(login)}"}],
        body: login
      }

      assert {:deny, 403, refused} = Gate.authorize(username, elsewhere)
      assert refused =~ "mwt_placeholder_blocked"
    end

    @tag :tmp_dir
    test "a refresh that is not of the login itself is refused before anything is minted",
         %{username: username, tmp_dir: dir} do
      grant = login_grant(username, dir)
      request = refresh(grant)
      body = String.replace(request.body, "refresh_token", "grant_type=authorization_code&x")
      request = %{request | body: body, headers: [{"content-length", "#{byte_size(body)}"}]}

      assert {:deny, 403, refused} = Gate.authorize(username, request)
      assert refused =~ "mwt_bad_request"
      refute File.exists?(Path.join(dir, "count"))
    end

    test "a grant that doesn't sign leaves the endpoint to the firewall", %{username: username} do
      {:ok, plain} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Plain Google",
          "purpose" => "Google APIs",
          "hosts" => "*.googleapis.com",
          "source" => "stored",
          "value" => "ya29.plain_value_0123456789"
        })

      {:ok, plain} = Sandbox.turn_on(username, plain.id, 60, :all)

      assert {:deny, 403, json} = authorize(username, sign_request(plain.placeholder, claims()))
      assert json =~ "mwt_credential_endpoint"
    end
  end
end
