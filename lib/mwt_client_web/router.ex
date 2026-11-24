defmodule MWTClientWeb.Router do
  use MWTClientWeb, :router

  pipeline :browser do
    plug MWTClientWeb.Plugs.LoopbackHost
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MWTClientWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MWTClientWeb.Plugs.ContentSecurityPolicy
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MWTClientWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [
        {MWTClientWeb.Hooks.Theme, :default},
        {MWTClientWeb.Hooks.Updates, :default}
      ] do
      live "/", LoginLive
    end

    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    live_session :app,
      on_mount: [
        {MWTClientWeb.UserAuth, :unlocked},
        {MWTClientWeb.Hooks.Theme, :default},
        {MWTClientWeb.Hooks.Updates, :default},
        {MWTClientWeb.Notices, :default},
        {MWTClientWeb.Hooks.Sandbox, :default},
        {MWTClientWeb.Hooks.Notifications, :default},
        {MWTClientWeb.Hooks.Places, :default}
      ] do
      live "/tools", ToolsLive
      live "/tools/http", HttpClientLive
      live "/tools/git", GitLive
      live "/tools/diagrams", DiagramsLive
      live "/tools/notes", NotesLive
      live "/tools/flashcards", FlashcardsLive, :remember
      live "/tools/flashcards/cards", FlashcardsLive, :cards
      live "/tools/flashcards/settings", FlashcardsLive, :settings
      live "/tools/sandbox", SandboxLive, :overview
      live "/tools/sandbox/approvals", SandboxLive, :approvals
      live "/tools/sandbox/projects", SandboxLive, :projects
      live "/tools/sandbox/handoffs", SandboxLive, :handoffs
      live "/tools/sandbox/grants", SandboxLive, :grants
      live "/tools/sandbox/grants/:id", SandboxLive, :grant
      live "/tools/sandbox/resources/:kind", SandboxLive, :resource
      live "/tools/sandbox/resources/:kind/:id", SandboxLive, :resource
      live "/tools/sandbox/activity", SandboxLive, :activity
      live "/tools/sandbox/firewall", SandboxLive, :firewall
      live "/tools/sandbox/settings", SandboxLive, :settings
      live "/tools/sandbox/setup", SandboxLive, :setup
      live "/notifications", NotificationsLive
      live "/transfer", TransferLive
      live "/storage", StorageLive
      live "/agents", AgentAccessLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", MWTClientWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:mwt_client, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: MWTClientWeb.Telemetry,
        csp_nonce_assign_key: :csp_nonce
    end
  end
end
