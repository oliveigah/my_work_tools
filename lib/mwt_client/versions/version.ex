defmodule MWTClient.Versions.Version do
  @moduledoc """
  One earlier version of a note, a diagram or a flash card: its `content`
  as it was, and the change that replaced it.

    * `version` - the item's version number while it held this content;
    * `content` - what a version keeps: a note's `:title` and `:body`, a
      diagram's `:title` and `:elements`, a card's `:front`, `:back`,
      `:tags` and `:source`;
    * `saved_at` - when this content was saved;
    * `replaced_at` and `replaced_by` - when, and by whom
      (`t:MWTClient.Versions.by/0`), it was replaced;
    * `how` - `:edit`, or `:restore` when an earlier version replaced it.
  """

  @enforce_keys [:version, :content, :saved_at, :replaced_at, :replaced_by, :how]
  defstruct [:version, :content, :saved_at, :replaced_at, :replaced_by, :how]

  @type t :: %__MODULE__{
          version: pos_integer(),
          content: map(),
          saved_at: DateTime.t(),
          replaced_at: DateTime.t(),
          replaced_by: MWTClient.Versions.by(),
          how: :edit | :restore
        }
end
