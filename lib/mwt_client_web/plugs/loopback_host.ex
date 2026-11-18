defmodule MWTClientWeb.Plugs.LoopbackHost do
  @moduledoc """
  Rejects requests whose `Host` is not a loopback name.

  Binding to 127.0.0.1 keeps the network out, but it does not stop DNS
  rebinding: a page the user visits can point its own domain at 127.0.0.1, and
  the browser will then treat this app as same origin. `check_origin` cannot
  catch that, because the attacker controls the `Origin` *and* the `Host`, so
  the two agree. Pinning the accepted host names does catch it.

  In development, any `127.x.y.z` address is accepted too
  (`:any_loopback_address`, set in `config/dev.exs`): an MWT run in the
  agent sandbox's VM opens on the user's machine at the VM's own address
  there (`MWTClient.Sandbox.Ports`). An address is never a name, so DNS
  rebinding can't use it. `origin?/2` is the same rule for `check_origin`.

  Disabled when the endpoint is deliberately bound to a public interface.
  """

  import Plug.Conn

  @loopback ~w(127.0.0.1 localhost ::1)

  def init(opts), do: opts

  def call(conn, _opts) do
    if enforce?() and not loopback?(conn.host) do
      conn |> send_resp(403, "Forbidden") |> halt()
    else
      conn
    end
  end

  @doc """
  Whether a page at `uri` may open MWT's sockets on `port`: plain HTTP, a
  loopback name, and MWT's own port. `check_origin` calls it with each
  socket's `Origin`.
  """
  @spec origin?(URI.t(), :inet.port_number()) :: boolean()
  def origin?(%URI{scheme: "http", host: host, port: port}, port) when is_binary(host),
    do: loopback?(host |> String.trim_leading("[") |> String.trim_trailing("]"))

  def origin?(_uri, _port), do: false

  defp loopback?(host) when host in @loopback, do: true

  defp loopback?(host) do
    any_address?() and
      match?({:ok, {127, _, _, _}}, :inet.parse_strict_address(String.to_charlist(host)))
  end

  defp any_address?, do: Application.get_env(:mwt_client, :any_loopback_address, false)

  defp enforce?, do: Application.get_env(:mwt_client, :require_loopback_host, true)
end
