defmodule MWTClient.Sandbox.Egress.Request do
  @moduledoc """
  One request a driver read on one of the VM's calls (a TCP connection; a
  UDP flow, once a core carries them), as everything past the driver sees
  it: the judge (`MWTClient.Sandbox.Gate.authorize/2`), the
  approval cards and the log. Whatever the protocol (an HTTP request, a
  Postgres query, a Kafka produce), it is one of these, so none of them
  needs a clause per protocol.

    * `id` - the request's own, also its exchange's in the log;
    * `driver` - the driver that read it (`MWTClient.Sandbox.Egress.Driver`),
      the only one that reads `data`, and the one whose `describe/1` makes
      its card;
    * `name`, `port` - where it goes: the host the client named (TLS's SNI;
      over plain HTTP, its `Host`), or its address when it named none
      (`Driver.host/1`), and the port;
    * `ip` - the address it goes to, as the destination check approved;
    * `plain?` - whether it came as plain bytes, not inside TLS MWT ended:
      then nothing proves `name` is the host at `ip`, only the client says
      so, and no real value goes in it;
    * `under` - the grant the connection went under (`Gate.destination/3`),
      or `:read_only` while only a token grant's hosts may be reached;
    * `operation` - what it does, in the protocol's own word: `GET`, `QUERY`,
      `PRODUCE`. The log shows it as a request's method;
    * `resource` - what it does it to: a path, a table, a topic; nil when the
      protocol has none. The log shows it as a request's path;
    * `data` - the rest, the driver's own: for HTTP/1.1 its version, headers
      and the start of its body.
  """

  @enforce_keys [:id, :driver, :port, :operation]
  defstruct [:id, :driver, :name, :ip, :port, :under, :operation, :resource, :data, plain?: false]

  @type t :: %__MODULE__{
          id: String.t(),
          driver: module(),
          name: String.t(),
          ip: :inet.ip_address() | nil,
          port: :inet.port_number(),
          plain?: boolean(),
          under: String.t() | :read_only | nil,
          operation: String.t(),
          resource: String.t() | nil,
          data: term()
        }
end
