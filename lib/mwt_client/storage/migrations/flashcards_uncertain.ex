defmodule MWTClient.Storage.Migrations.FlashcardsUncertain do
  @moduledoc """
  `library.db`, version 3: a flash card the user marked uncertain
  (`MWTClient.Flashcards.Card`), as they doubt its answer, until an agent
  or they themselves check it.

  `uncertain_at` says when it was marked, null while it isn't;
  `uncertain_note` what they doubt, null when they wrote nothing. A
  session never asks a marked card, so the picks and counts that read
  every card ask for the marked ones apart.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE flashcards ADD COLUMN uncertain_at INTEGER")
    execute("ALTER TABLE flashcards ADD COLUMN uncertain_note TEXT")
  end

  def down do
    execute("ALTER TABLE flashcards DROP COLUMN uncertain_note")
    execute("ALTER TABLE flashcards DROP COLUMN uncertain_at")
  end
end
