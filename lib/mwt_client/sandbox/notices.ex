defmodule MWTClient.Sandbox.Notices do
  @moduledoc """
  What the sandbox notifies you of (`MWTClient.Notifications`): an approval
  that waits for you, and a handoff that waits for your review. Clicking one
  opens it in MWT.

  For an approval: what waits, who asked, and how long it waits. The thread
  it asked from (`MWTClient.Sandbox.Approval.asked_from/2`) comes first, so
  you know which of your agents waits. What the agent wrote (its reason) is
  quoted, as on the approval's card, and nothing in a notification is a way
  to decide: the card is, with the facts MWT worked out beside it.

  For a handoff: who handed what off, onto which branch, and how big it is.
  """

  alias MWTClient.Sandbox.{Approval, Grant, Handoff, Handoffs, HostCommand}

  @doc "The notice for `approval`, waiting for you; `grant` is its grant, if any."
  @spec approval(Approval.t(), Grant.t() | nil, DateTime.t()) :: MWTClient.Notifications.notice()
  def approval(%Approval{} = approval, grant, now \\ DateTime.utc_now()) do
    {summary, lines} = text(approval, grant)

    %{
      kind: "sandbox.approvals",
      summary: summary,
      body: Enum.join(Enum.reject(lines ++ [gives_up(approval, now)], &(&1 in [nil, ""])), "\n"),
      open: "/tools/sandbox/approvals?focus=" <> approval.id
    }
  end

  @doc "The notice for an open `handoff`, waiting for your review."
  @spec handoff(Handoff.t()) :: MWTClient.Notifications.notice()
  def handoff(%Handoff{} = handoff) do
    verb = if handed_off(handoff) > 1, do: "updated", else: "handed off"
    stats = handoff.stats || %{}

    size =
      "#{count(stats[:commits] || 0, "commit")}, #{count(stats[:files] || 0, "file")} " <>
        "(+#{stats[:added] || 0} −#{stats[:removed] || 0})"

    %{
      kind: "sandbox.handoffs",
      summary: "#{capital(Handoffs.who(handoff))} #{verb} ##{handoff.id}: #{handoff.title}",
      body:
        Enum.join(
          Enum.reject(
            [
              handoff.thread && "From " <> handoff.thread,
              "#{handoff.project}: #{handoff.source.branch}, based on #{Handoff.base_label(handoff)}",
              size
            ],
            &is_nil/1
          ),
          "\n"
        ),
      open: "/tools/sandbox/handoffs?id=#{handoff.id}"
    }
  end

  @doc "How many times the agent handed it off: once, then once per update."
  @spec handed_off(Handoff.t()) :: non_neg_integer()
  def handed_off(%Handoff{timeline: timeline}),
    do: Enum.count(timeline, &(&1.kind in [:opened, :updated]))

  defp capital(text) do
    {first, rest} = String.split_at(String.trim(text), 1)
    String.upcase(first) <> rest
  end

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  defp text(%Approval{kind: :activation, need: need} = approval, nil) do
    {"#{agent(approval)} asks for access you haven't set up",
     [from(approval), need, reason(approval)]}
  end

  defp text(%Approval{kind: :activation} = approval, grant) do
    minutes = if approval.minutes, do: "for #{approval.minutes} min", else: nil

    {"#{agent(approval)} asks to turn on #{name(grant)}",
     [from(approval), minutes && String.capitalize(minutes), reason(approval)]}
  end

  defp text(%Approval{kind: :request} = approval, grant),
    do: {"An agent wants to use #{name(grant)}", [approval.title]}

  defp text(%Approval{kind: :tool, tool: tool} = approval, _grant),
    do:
      {"#{agent(approval)} asks to #{lower(approval.title)}",
       [from(approval), tool && tool.words]}

  defp text(%Approval{kind: :connection} = approval, grant),
    do: {"An agent wants to connect through #{name(grant)}", [approval.pattern]}

  defp text(%Approval{kind: :command, stage: :output, run: run} = approval, _grant),
    do:
      {"A command's output waits for you",
       [from(approval), HostCommand.title(approval.script), ended(run)]}

  defp text(%Approval{kind: :command, script_from: :grant} = approval, grant) do
    {"#{agent(approval)} calls your action #{(grant && grant.name) || approval.grant_id}",
     [from(approval), reason(approval)]}
  end

  defp text(%Approval{kind: :command} = approval, _grant) do
    {"#{agent(approval)} asks to run a command it wrote, on this machine",
     [from(approval), HostCommand.title(approval.script), reason(approval)]}
  end

  # A card's title, as it reads after "asks to": "change note “Plan”".
  defp lower(title) do
    {first, rest} = String.split_at(title, 1)
    String.downcase(first) <> rest
  end

  defp agent(%Approval{agent: agent}) when is_binary(agent) and agent != "" do
    {first, rest} = String.split_at(String.trim(agent), 1)
    String.upcase(first) <> rest
  end

  defp agent(_approval), do: "An agent"

  # The thread it asked from, so you know which one waits before opening MWT.
  defp from(approval) do
    case Approval.asked_from(approval) do
      nil -> nil
      from -> "From " <> from
    end
  end

  defp name(%Grant{name: name}), do: name
  defp name(nil), do: "a grant"

  defp reason(%Approval{reason: reason}) when is_binary(reason) and reason != "",
    do: "Reason: “#{String.trim(reason)}”"

  defp reason(_approval), do: nil

  defp ended(%{exit: exit} = run) do
    cond do
      run[:timed_out] -> "Hit its time limit (exit #{exit})"
      run[:stopped] -> "Stopped by you (exit #{exit})"
      true -> "Exit #{exit}"
    end
  end

  defp ended(_run), do: nil

  defp gives_up(%Approval{deadline: deadline}, now) do
    seconds = max(DateTime.diff(deadline, now), 0)
    "Gives up in #{HostCommand.seconds_words(round_up(seconds))} unless you decide."
  end

  # "2 min 59 s" reads worse than "3 min" in a notification.
  defp round_up(seconds) when seconds > 90, do: div(seconds + 59, 60) * 60
  defp round_up(seconds), do: seconds
end
