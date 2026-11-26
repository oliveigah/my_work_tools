import Config

if log_dir = System.get_env("MWT_LOG_DIR") do
  config :mwt_client, log_dir: Path.expand(log_dir)
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mwt_client start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mwt_client, MWTClientWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))

# Public binding is opt in; everything else assumes this is a desktop app
# talking to its own WebView over loopback.
bind_all? = System.get_env("PHX_BIND_ALL") == "true"

config :mwt_client, :require_loopback_host, not bind_all?

config :mwt_client, MWTClientWeb.Endpoint, http: [port: port]

# An explicit allow list rather than `:conn`: `:conn` only checks that Origin
# agrees with Host, which a DNS rebinding attacker satisfies trivially.
# The rule is MWTClientWeb.Plugs.LoopbackHost's: loopback names on this port,
# and in development any 127.x.y.z address (see config/dev.exs).
unless bind_all? do
  config :mwt_client, MWTClientWeb.Endpoint,
    check_origin: {MWTClientWeb.Plugs.LoopbackHost, :origin?, [port]}
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :mwt_client, MWTClientWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/mwt_client_web/router\.ex$"E,
        ~r"lib/mwt_client_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base signs the session cookie and LiveView's tokens. One
  # written into the app would be the same in every copy of it, so anyone
  # could sign what MWT trusts. Sessions live only in memory
  # (MWTClientWeb.Session), so none outlives a restart anyway: a new key each
  # start costs nothing. SECRET_KEY_BASE is for a deployment that wants one
  # of its own.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  host = System.get_env("PHX_HOST") || "example.com"

  config :mwt_client, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # MWT is a desktop app holding one person's encrypted history, so it binds
  # loopback unless a deployment explicitly opts into a public interface. This
  # is deliberately the default rather than something a missing environment
  # variable can switch off: getting it wrong exposes a vault to the network.
  config :mwt_client, MWTClientWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: if(bind_all?, do: {0, 0, 0, 0, 0, 0, 0, 0}, else: {127, 0, 0, 1})],
    secret_key_base: secret_key_base

  # The desktop WebView connects over local HTTP, including its LiveView socket.
  if System.get_env("ELIXIRKIT_PUBSUB") do
    config :mwt_client, MWTClientWeb.Endpoint,
      url: [host: host, port: String.to_integer(System.fetch_env!("PORT")), scheme: "http"]
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mwt_client, MWTClientWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mwt_client, MWTClientWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
