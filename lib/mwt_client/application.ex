defmodule MWTClient.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = MWTClient.LogFile.install()
    pubsub = System.get_env("ELIXIRKIT_PUBSUB")
    discard_legacy_history()

    require Logger
    Logger.info("MWT starting", system: :app)

    children = [
      MWTClientWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:mwt_client, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MWTClient.PubSub},
      MWTClient.Notifications.Center,
      {Task.Supervisor, name: MWTClient.HttpClient.TaskSupervisor},
      {Task.Supervisor, name: MWTClient.Sandbox.TaskSupervisor},
      MWTClient.Updates,
      MWTClient.Preferences,
      # The agent sandbox's open proxy connections, by identity: isolating
      # the VM closes them (`MWTClient.Sandbox.Server.Firewall`).
      {Registry, keys: :duplicate, name: MWTClient.Sandbox.Connections},
      # What the network path decides from, published by each identity's
      # sandbox (`MWTClient.Sandbox.Gate`): its table outlives a restart of
      # one.
      MWTClient.Sandbox.Gate,
      MWTClient.Vault.Store,
      MWTClientWeb.Session,
      # Start a worker by calling: MWTClient.Worker.start_link(arg)
      # {MWTClient.Worker, arg},
      # Start to serve requests, typically the last entry
      {ElixirKit.PubSub, connect: pubsub || :ignore, on_exit: fn -> System.stop() end},
      MWTClientWeb.Endpoint,
      {Task,
       fn ->
         if pubsub do
           ElixirKit.PubSub.broadcast("messages", "ready")
         end
       end}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MWTClient.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Request history predates per identity encryption and was written in the
  # clear. There is no identity to migrate it into, so it goes.
  defp discard_legacy_history do
    legacy = Path.join(MWTClient.Accounts.root(), "http_client_history.ets")

    if File.exists?(legacy) do
      File.rm(legacy)
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MWTClientWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
