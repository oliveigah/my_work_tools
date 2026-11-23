defmodule MWTClient.QAProbes.FirewallUI.ListDraftTest do
  @moduledoc """
  Probe: on the Firewall page, an unrelated change (a new finding) makes
  the server send every list's textarea content again, though no list
  changed. In the browser, morphdom then writes it over any textarea that
  doesn't have focus: a list half edited in another tab is lost.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox.Gate

  @moduletag :capture_log

  setup %{conn: conn}, do: sign_in(conn, "qa-draft")

  defp drain(acc) do
    receive do
      {:trace, _pid, :send, msg, _to} ->
        drain([inspect(msg, limit: :infinity, printable_limit: :infinity) | acc])
    after
      0 -> acc
    end
  end

  test "a finding re-sends the lists' text", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/firewall")
    _ = :sys.get_state(view.pid)

    :erlang.trace(view.pid, true, [:send])

    # The VM looks up a DNS-over-HTTPS resolver: a finding (Block), nothing about the lists.
    :refuse = Gate.lookup(username, "dns.google")
    send(view.pid, :refresh)
    _ = :sys.get_state(view.pid)
    :erlang.trace(view.pid, false, [:send])

    sent = drain([]) |> Enum.join("\n")
    diffs = sent |> String.split("\n") |> Enum.filter(&String.contains?(&1, "diff"))

    IO.puts("""

    finding shown: #{has_element?(view, "#firewall-findings", "dns.google")}
    diff messages: #{length(diffs)}
    a diff re-sends the trusted list's text (*.anthropic.com): #{String.contains?(sent, "*.anthropic.com")}
    a diff re-sends the blocked list's text (pastebin.com): #{String.contains?(sent, "pastebin.com")}
    """)

    assert String.contains?(sent, "*.anthropic.com")
  end
end
