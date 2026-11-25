defmodule MWTClient.Sandbox.PolicyExceptTest do
  @moduledoc """
  A network grant that leaves hosts out (`Grant.except`): it covers its
  part of the network but those, so another grant over them decides them
  on its own terms. Grants still only give: the Internet's grant
  auto-approving everything but `myhost.xpto.com`, a grant over that host
  that asks makes it ask; with none on, it is refused, never let through.
  """
  use MWTClient.PolicyCase, async: true

  @ip {93, 184, 216, 34}

  defp internet(attrs \\ []) do
    struct!(
      %Grant{
        id: "internet",
        name: "Internet",
        kind: :network,
        internet: true,
        state: :on,
        allowances: [allowance(:all, nil)],
        except: ["myhost.xpto.com"]
      },
      attrs
    )
  end

  # A grant over part of the Internet naming the host, asking each time.
  defp myhost(attrs \\ []) do
    struct!(
      %Grant{
        id: "myhost",
        name: "My host",
        kind: :network,
        network: "internet",
        state: :on,
        scope: ["myhost.xpto.com"],
        destinations: ["myhost.xpto.com"],
        allowances: []
      },
      attrs
    )
  end

  defp request(host),
    do: %{host: host, method: "GET", path: "/", headers: [], body: "", under: "internet"}

  defp decide(grants, use), do: grants |> snapshot() |> Policy.decide(use, @now)

  describe "a request" do
    test "to a host the Internet leaves out: refused with no grant over it, the host and the names under it" do
      for host <- ["myhost.xpto.com", "api.myhost.xpto.com", "MyHost.xpto.com"] do
        assert {:refuse, {:excepted, %{id: "internet"}, "myhost.xpto.com"}} =
                 decide([internet()], {:network_request, request(host)})
      end

      # Any other host is the Internet's, as before; a name merely ending
      # the same way isn't under it.
      for host <- ["example.org", "xpto.com", "notmyhost.xpto.com"] do
        assert :pass = decide([internet()], {:network_request, request(host)})
      end
    end

    test "a grant over the host decides it: it asks while the Internet lets the rest through" do
      use = {:network_request, request("myhost.xpto.com")}

      for grants <- [[internet(), myhost()], [myhost(), internet()]] do
        assert {:ask, %{id: "myhost"}, %{title: "GET myhost.xpto.com/"}} = decide(grants, use)
      end

      assert {:allow, %{id: "myhost"}, _, _} =
               decide([internet(), myhost(allowances: [allowance(:all, nil)])], use)

      # Its grant off or ended, the host is refused, not let through.
      assert {:refuse, {:grant_off, %{id: "myhost"}}} =
               decide([internet(), myhost(state: :off)], use)

      assert {:refuse, {:grant_off, %{id: "myhost"}}} =
               decide([internet(), myhost(expires_at: @earlier)], use)
    end

    test "with nothing left out, the most permissive grant counts, as ever: grants only give" do
      use = {:network_request, request("myhost.xpto.com")}
      assert :pass = decide([internet(except: []), myhost()], use)
    end

    test "a request with no credential is decided by its network the same way" do
      assert {:refuse, {:excepted, %{id: "internet"}, "myhost.xpto.com"}} =
               decide([internet()], {:request, request("myhost.xpto.com")})

      assert {:ask, %{id: "myhost"}, _} =
               decide([internet(), myhost()], {:request, request("myhost.xpto.com")})
    end

    test "a grant over part of a private network leaves hosts out the same way" do
      corp = %Grant{
        id: "corp",
        name: "Corp",
        kind: :network,
        state: :on,
        destinations: ["*.corp.example:443"],
        allowances: [allowance(:all, nil)],
        except: ["secret.corp.example"]
      }

      use = fn host -> {:network_request, %{request(host) | under: "corp"}} end

      assert {:allow, %{id: "corp"}, _, _} = decide([corp], use.("git.corp.example"))

      assert {:refuse, {:excepted, %{id: "corp"}, "secret.corp.example"}} =
               decide([corp], use.("secret.corp.example"))
    end
  end

  describe "a connection" do
    test "to an address answered for a host left out waits for its first bytes" do
      decide = fn grants, answered ->
        grants
        |> snapshot()
        |> Map.put(:answered, answered)
        |> Policy.decide({:connection, @ip, 443}, @now)
      end

      assert {:allow, %{id: "internet"}, _, _} = decide.([internet()], %{})
      assert {:allow, %{id: "internet"}, _, _} = decide.([internet()], %{@ip => ["example.org"]})

      assert {:ask, %{id: "internet"}, _} =
               decide.([internet()], %{@ip => ["example.org", "myhost.xpto.com"]})

      # Named by a grant over it, that grant opens it, as its approval says.
      assert {:ask, %{id: "myhost"}, _} =
               decide.([internet(), myhost()], %{@ip => ["myhost.xpto.com"]})
    end

    test "MWT can't read: judged by every name it may be for, a host left out among them" do
      decide = fn grants, asked, answered ->
        grants
        |> snapshot()
        |> Map.put(:answered, answered)
        |> Policy.decide({:unread, @ip, 443, [asked]}, @now)
      end

      assert {:refuse, {:excepted, %{id: "internet"}, "myhost.xpto.com"}} =
               decide.([internet()], "myhost.xpto.com", %{})

      # The name it asked for proves nothing: one MWT's DNS answered for
      # the address counts too.
      assert {:refuse, {:excepted, _, _}} =
               decide.([internet()], "example.org", %{@ip => ["myhost.xpto.com"]})

      assert {:allow, %{id: "internet"}, _, _} = decide.([internet()], "example.org", %{})

      assert {:ask, %{id: "myhost"}, _} =
               decide.([internet(), myhost()], "myhost.xpto.com", %{})
    end
  end

  test "exceptions from a form: host names, the names under them, no addresses" do
    alias MWTClient.Sandbox.Network

    assert {:ok, ["myhost.xpto.com", "*.tracker.example"]} =
             Network.except_entries("https://MyHost.xpto.com:8443/x\n *.tracker.example ,")

    assert {:ok, []} = Network.except_entries("")
    assert {:error, _} = Network.except_entries("10.0.0.0/8")

    assert {:error, "At most 200 hosts."} =
             1..201 |> Enum.map(&"h#{&1}.example") |> Network.except_entries()
  end
end
