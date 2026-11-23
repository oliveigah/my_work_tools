defmodule MWTClientWeb.Plugs.ContentSecurityPolicyTest do
  use MWTClientWeb.ConnCase, async: true

  test "a page loads images, media and fonts only from MWT, and only its own scripts",
       %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    [policy] = get_resp_header(conn, "content-security-policy")
    directives = policy |> String.split(";") |> Map.new(&split_directive/1)

    assert directives["img-src"] == ["'self'", "data:", "blob:"]
    assert directives["media-src"] == ["'self'", "data:", "blob:"]
    assert directives["font-src"] == ["'self'", "data:"]
    assert directives["object-src"] == ["'none'"]
    assert ["'self'", "'nonce-" <> nonce] = directives["script-src"]
    nonce = String.trim_trailing(nonce, "'")

    # The root layout's inline script is the only one, and carries it.
    scripts = html |> LazyHTML.from_document() |> LazyHTML.query("script:not([src])")
    assert LazyHTML.attribute(scripts, "nonce") == [nonce]

    [again] = build_conn() |> get(~p"/") |> get_resp_header("content-security-policy")
    refute again =~ nonce
  end

  defp split_directive(directive) do
    [name | values] = String.split(directive)
    {name, values}
  end
end
