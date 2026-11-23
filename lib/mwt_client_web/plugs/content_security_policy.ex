defmodule MWTClientWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  What MWT's pages may load, as a Content-Security-Policy on every page.

  Pages show text that others wrote: notes, flash cards and handoffs from
  agents in the sandbox's VM, imports. `MWTClient.Markdown` and
  `MWTClient.Sandbox.Shown` keep that text from becoming markup, and this
  is the second line, for the day one of them misses something:

    * `img-src`, `media-src`, `font-src`: MWT's own files and inline data
      only. An address in the page would be fetched from this machine the
      moment the page opens, wherever the author pointed it (your
      loopback, your network), outside the sandbox's proxy, with whatever
      the address carries.
    * `script-src`: MWT's own files, and the root layout's inline script by
      a nonce made for each page (`@csp_nonce`).
    * `object-src 'none'`, `base-uri 'self'`, `frame-ancestors 'self'`,
      `form-action 'self'`.

  Left open on purpose: styles, since templates set `style` attributes;
  `connect-src`, which LiveView's socket and the desktop shell's own calls
  use, and which a script would need first; frames, which the development
  live reload uses. The desktop shell loads these pages from MWT's address
  (`src-tauri/src/lib.rs`), so this header is what applies there too: its
  own `csp` setting is only for files it serves itself.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  @doc "The policy for a page whose inline script carries `nonce`."
  @spec policy(String.t()) :: String.t()
  def policy(nonce) do
    Enum.join(
      [
        "img-src 'self' data: blob:",
        "media-src 'self' data: blob:",
        "font-src 'self' data:",
        "script-src 'self' 'nonce-#{nonce}'",
        "object-src 'none'",
        "base-uri 'self'",
        "frame-ancestors 'self'",
        "form-action 'self'"
      ],
      "; "
    )
  end
end
