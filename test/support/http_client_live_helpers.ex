defmodule MWTClientWeb.HttpClientLiveHelpers do
  @moduledoc """
  What the tests of the HTTP client's page share: the page open on an
  identity of the test's own, whose history holds two requests
  (`with_history/1`, a setup). Each test has its own, so the modules that
  use it run side by side.
  """

  # `live/2` gets the page through `Phoenix.ConnTest.get/2`, which reads
  # `@endpoint`.
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  alias MWTClient.HttpClient.{HistoryMetadata, Resources}

  @endpoint MWTClientWeb.Endpoint

  @doc """
  A setup: signs in (`:conn`, `:username`), records a health check
  (`:health_id`) and an order in the history, and opens the page (`:view`).
  """
  def with_history(%{conn: conn}) do
    %{conn: conn, username: username} = MWTClientWeb.ConnCase.sign_in(conn)

    health_request =
      Req.new(
        method: :get,
        url: "https://api.example.test/health",
        headers: [{"accept", "application/json"}]
      )

    health_response = %Req.Response{
      status: 200,
      headers: %{"content-type" => ["application/json"], "x-ratelimit-remaining" => ["4998"]},
      body: %{"status" => "ok"}
    }

    health_id =
      Resources.record(
        username,
        HistoryMetadata.new(%{description: "Health check", tags: ["system", "health"]}),
        health_request,
        health_response
      )

    Resources.record(
      username,
      HistoryMetadata.new(%{description: "Create order", tags: ["orders"]}),
      Req.new(method: :post, url: "https://api.example.test/orders", body: ~s({"sku":"MWT-PRO"})),
      %Req.Response{status: 201, headers: %{}, body: %{"id" => "ord_1"}}
    )

    {:ok, view, _html} = live(conn, "/tools/http")
    %{view: view, health_id: health_id, username: username, conn: conn}
  end
end
