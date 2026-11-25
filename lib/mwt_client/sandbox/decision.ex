defmodule MWTClient.Sandbox.Decision do
  @moduledoc """
  Who or what decided an action, as the activity log keeps it with the
  action's line (`MWTClient.Sandbox.Event`): an answer, later, to "did it
  go through, and what let it?", with what decided it as it was then.

  `by` is one of:

    * `:you` - you, on a card (`card`: its id; the card is kept whole,
      read-only, `MWTClient.Storage.Journal.card/2`), whatever you chose:
      allowed once, allowed similar, denied;
    * `:allowance` - a standing yes of a grant let it through unasked
      (`allowance`): the grant on Auto-approve, its start setting, or an
      *Allow similar* you chose on an earlier card, whose id is `card`;
    * `:grant` - a grant that is on let it through, one that asks for no
      use of this kind: a lookup, a connection whose requests are judged
      one by one, a tunnel under the grant it went under;
    * `:refused` - MWT refused it (`why`), whatever any grant says: off,
      locked, blocked, isolated, outside every grant;
    * `:timeout` - its card waited for you until its time ran out.

  `allowed` says whether it went through. `settled` is the card a card's
  line is about, when it was decided: the card itself for yours, the one
  an allowance let through for an allowance's. `grant` names the grant
  that decided, and `version` the state it was in (`version_id/1`), so the
  log can say whether it changed since.

  While a decision is built it carries the card to keep beside it, which
  `MWTClient.Sandbox.Server.State.log/2` writes and drops (`kept/1`).
  """

  alias MWTClient.Sandbox.{Allowance, Approval, Grant}

  @type by :: :you | :allowance | :grant | :refused | :timeout
  @type t :: %{
          required(:by) => by(),
          optional(:card) => String.t() | nil,
          optional(:grant) => String.t() | nil,
          optional(:version) => String.t() | nil,
          optional(:allowance) => map() | nil,
          optional(:choice) => String.t() | nil,
          optional(:allowed) => boolean(),
          optional(:settled) => String.t() | nil,
          optional(:why) => String.t() | nil
        }

  @doc "Every way an action is decided, as the activity log's filter offers them."
  @spec all() :: [by()]
  def all, do: [:you, :allowance, :grant, :refused, :timeout]

  @doc "Refused by MWT, `why` in a few words."
  @spec refused(String.t()) :: t()
  def refused(why), do: %{by: :refused, why: why, allowed: false}

  @doc "Waited on its card, `card`, until its time ran out."
  @spec timeout(Approval.t()) :: t()
  def timeout(%Approval{} = card),
    do: %{by: :timeout, card: card.id, choice: "it timed out", allowed: false, keep_card: card}

  @doc """
  Decided by you on `card`, choosing `choice` (in the log's words), which
  let it through or not (`allowed?`); the card's grant as it was then.
  """
  @spec you(Approval.t(), String.t(), Grant.t() | nil, boolean()) :: t()
  def you(%Approval{} = card, choice, grant, allowed?) do
    %{by: :you, card: card.id, choice: choice, allowed: allowed?, keep_card: card}
    |> with_grant(grant)
  end

  @doc "Let through by `grant`, on, which asks for no use of this kind."
  @spec grant(Grant.t()) :: t()
  def grant(%Grant{} = grant), do: with_grant(%{by: :grant, allowed: true}, grant)

  @doc "Let through by `allowance`, a standing yes of `grant`."
  @spec allowance(Grant.t(), Allowance.t()) :: t()
  def allowance(%Grant{} = grant, %Allowance{} = allowance) do
    origin = allowance.origin || %{}

    %{
      by: :allowance,
      allowed: true,
      card: origin[:card],
      allowance: %{
        id: allowance.id,
        pattern: allowance.pattern,
        until: allowance.until,
        origin: origin
      }
    }
    |> with_grant(grant)
  end

  @doc """
  What let through a use the policy passed without a word (`:pass`): the
  Internet's grant, auto-approving, by its allowance for every use; nil
  when nothing among `grants` did.
  """
  @spec passed([Grant.t()], DateTime.t()) :: t() | nil
  def passed(grants, now \\ DateTime.utc_now()) do
    with %Grant{} = internet <- Enum.find(grants, &Grant.internet?/1),
         %Allowance{} = every <-
           Enum.find(internet.allowances, &(&1.pattern == :all and not Allowance.ended?(&1, now))) do
      allowance(internet, every)
    else
      _none -> nil
    end
  end

  defp with_grant(decision, nil), do: decision

  defp with_grant(decision, %Grant{} = grant),
    do: Map.merge(decision, %{grant: grant.id, version: version_id(grant)})

  @doc """
  The id of `grant`'s state as it is: the same for the same settings,
  state and allowances, whatever it was used, so the log can tell a grant
  changed since it decided.

      iex> alias MWTClient.Sandbox.{Decision, Grant}
      iex> grant = %Grant{id: "g", name: "G", kind: :token}
      iex> Decision.version_id(grant) == Decision.version_id(%{grant | uses: 3})
      true
      iex> Decision.version_id(grant) == Decision.version_id(%{grant | state: :on})
      false
  """
  @spec version_id(Grant.t()) :: String.t()
  def version_id(%Grant{} = grant) do
    used_aside = %{grant | uses: 0, last_used_at: nil}
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(used_aside, [:deterministic]))
    "gv-" <> binary_part(Base.url_encode64(hash, padding: false), 0, 24)
  end

  @doc """
  The decision as the line keeps it, and the card to keep beside it, nil
  when there is none: `%{card: approval, choice: words}`, what was chosen
  on it, so it opens as decided from any line naming it.
  """
  @spec kept(t()) :: {t(), map() | nil}
  def kept(decision) do
    card =
      case decision[:keep_card] do
        nil ->
          nil

        # A tool's call holds the function that makes it: not the card's.
        %Approval{tool: %{} = tool} = card ->
          %{card: %{card | tool: Map.delete(tool, :apply)}, choice: decision[:choice]}

        card ->
          %{card: card, choice: decision[:choice]}
      end

    {Map.delete(decision, :keep_card), card}
  end

  @doc """
  What an action's line says was decided when nothing said so where it
  was logged: a refusal, or a card that timed out, by its outcome; nil
  for anything else.
  """
  @spec inferred(atom(), String.t()) :: t() | nil
  # The reason alone: a line's summary says what it was first, then why.
  def inferred(outcome, summary) when outcome in [:blocked, :refused, :violation, :read_failed],
    do: refused(summary |> String.split(" · ") |> List.last())

  def inferred(:timed_out, _summary), do: %{by: :timeout, allowed: false}
  def inferred(_outcome, _summary), do: nil

  @doc """
  Whether the action went through: what its decision says, or, for a line
  whose decision doesn't, what its `outcome` says, so the audit and the
  line's badge never disagree.

      iex> alias MWTClient.Sandbox.Decision
      iex> Decision.allowed?(%{by: :you, allowed: false}, :allowed)
      false
      iex> Decision.allowed?(%{by: :you}, :allowed)
      true
      iex> Decision.allowed?(%{by: :you}, :denied)
      false
  """
  @spec allowed?(t(), atom()) :: boolean()
  def allowed?(%{allowed: allowed}, _outcome) when is_boolean(allowed), do: allowed

  def allowed?(_decision, outcome),
    do: outcome not in [:denied, :refused, :blocked, :violation, :read_failed, :timed_out]

  @doc "Who or what decided, in a few words: the audit's *Decided by*."
  @spec by_words(t()) :: String.t()
  def by_words(%{by: :you}), do: "You, on a card"
  def by_words(%{by: :allowance}), do: "Auto-approve"
  def by_words(%{by: :grant}), do: "A grant that is on"
  def by_words(%{by: :refused}), do: "MWT"
  def by_words(%{by: :timeout}), do: "Nobody"

  @doc """
  Why, in one line, the same way for every action: the audit's *Because*.

      iex> MWTClient.Sandbox.Decision.because(%{by: :you, choice: "you allowed once"})
      "You allowed once"
  """
  @spec because(t()) :: String.t()
  def because(%{by: :you} = decision), do: String.capitalize(decision[:choice] || "you decided")

  def because(%{by: :allowance, allowance: allowance}) do
    what =
      case allowance.origin do
        %{kind: :card} -> "Allow similar, which you chose on an earlier card"
        %{kind: :auto} -> "You turned the grant on with Auto-approve"
        %{kind: :start} -> "The grant starts on with Auto-approve"
        %{kind: :you} -> "You allowed every use, from the grant's page"
        %{kind: :mwt} -> "A rule of MWT's own"
        _unknown -> "A standing yes of the grant"
      end

    if allowance.until,
      do: "#{what}, until #{Calendar.strftime(allowance.until, "%H:%M")} UTC",
      else: what
  end

  def because(%{by: :grant}), do: "The grant was on, and asks for no use of this kind"
  def because(%{by: :refused} = decision), do: decision[:why] || "Refused"
  def because(%{by: :timeout}), do: "Its card timed out"
end
