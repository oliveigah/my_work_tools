defmodule MWTClient.SandboxH2Host do
  @moduledoc """
  A host for tests of MWT's HTTP/2 driver, served by Bandit over TLS: what
  it answers says what reached it.

    * `GET /hello` - `hello`;
    * `GET /auth` - `ok`, with what came as `authorization` in `x-auth`;
    * `GET /echo-auth` - what came as `authorization`, as the body;
    * `POST /size` - how many bytes the body had;
    * `GET /big` - 2 MiB of `a`;
    * anything else - its path.
  """
  @behaviour Plug

  import Plug.Conn

  alias MWTClient.Sandbox.CertificateAuthority, as: CA

  @doc "Starts it for `name`, its certificate from a CA of its own; `{pid, port}`."
  def start(name \\ "example.com") do
    leaf = CA.leaf(CA.new("#{name}'s CA"), name)

    {:ok, pid} =
      Bandit.start_link(
        plug: __MODULE__,
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: [transport_options: CA.ssl_options(leaf)]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, port}
  end

  @impl true
  def init(options), do: options

  @impl true
  def call(%{method: "GET", request_path: "/hello"} = conn, _options),
    do: send_resp(conn, 200, "hello")

  def call(%{method: "GET", request_path: "/auth"} = conn, _options) do
    conn
    |> put_resp_header("x-auth", conn |> get_req_header("authorization") |> Enum.join())
    |> send_resp(200, "ok")
  end

  def call(%{method: "GET", request_path: "/echo-auth"} = conn, _options),
    do: send_resp(conn, 200, conn |> get_req_header("authorization") |> Enum.join())

  def call(%{method: "POST", request_path: "/size"} = conn, _options) do
    {size, conn} = read_all(conn, 0)
    send_resp(conn, 200, "#{size}")
  end

  def call(%{method: "GET", request_path: "/big"} = conn, _options),
    do: send_resp(conn, 200, String.duplicate("a", 2 * 1024 * 1024))

  def call(conn, _options), do: send_resp(conn, 200, conn.request_path)

  defp read_all(conn, size) do
    case read_body(conn, length: 64 * 1024) do
      {:ok, data, conn} -> {size + byte_size(data), conn}
      {:more, data, conn} -> read_all(conn, size + byte_size(data))
    end
  end
end
