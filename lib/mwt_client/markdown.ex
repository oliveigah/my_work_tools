defmodule MWTClient.Markdown do
  @moduledoc """
  Renders Markdown to HTML, through `MDEx`, for every app in MWT: a note's
  body, the description an agent writes for a handoff. Pages show it with
  `MWTClientWeb.MarkdownComponents`.

  It is GitHub flavoured: tables, task lists, strikethrough and bare links
  all work, and a single line break is kept, so text reads as it was typed.

  What it renders is not only typed here (agents write handoffs, notes come
  from imports and MCP clients), so nothing in it is trusted. Comrak's safe
  mode leaves raw HTML out and empties links to scripts and local files,
  which is what makes the result fit to be put on the page as it is. Links
  open in a new window, which the desktop shell hands to the system browser
  rather than navigating MWT away from itself.
  """

  @options [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
    render: [unsafe: false, hardbreaks: true]
  ]

  @doc "The HTML for `markdown`, safe to render as is."
  @spec to_html(String.t()) :: String.t()
  def to_html(markdown) when is_binary(markdown) do
    markdown
    |> MDEx.to_html!(@options)
    # Every anchor comes from comrak itself: raw HTML is left out and text
    # is escaped, so nothing written in the Markdown can match this.
    |> String.replace("<a href=", ~s(<a target="_blank" rel="noopener noreferrer" href=))
  end
end
