defmodule MWTClient.Flashcards.Settings do
  @moduledoc """
  How remember sessions run, for one identity:

    * `session_size` - how many cards a session asks, unless it is started
      with another number;
    * `repeat_forgotten` - whether a card forgotten comes back before the
      session ends;
    * `fill` - whether a session with fewer cards due than its size is
      filled with the cards coming due soonest, or asks only those due.
  """

  @max_size 100

  @type t :: %__MODULE__{
          session_size: pos_integer(),
          repeat_forgotten: boolean(),
          fill: boolean()
        }

  defstruct session_size: 10, repeat_forgotten: true, fill: true

  @doc "The most cards one session asks."
  def max_size, do: @max_size

  @doc """
  Applies `attrs`, from a form (string keys and values) or from code (atom
  keys), to `settings`. Values out of range are brought into it, and
  anything unreadable leaves the setting as it was.
  """
  @spec change(t(), map()) :: t()
  def change(%__MODULE__{} = settings, attrs) when is_map(attrs) do
    %__MODULE__{
      session_size: size(fetch(attrs, :session_size), settings.session_size),
      repeat_forgotten: flag(fetch(attrs, :repeat_forgotten), settings.repeat_forgotten),
      fill: flag(fetch(attrs, :fill), settings.fill)
    }
  end

  @doc "A session size from a form or an agent, or `default` when it is not a number."
  @spec size(term(), pos_integer()) :: pos_integer()
  def size(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> size(number, default)
      _other -> default
    end
  end

  def size(value, _default) when is_integer(value), do: value |> max(1) |> min(@max_size)
  def size(_value, default), do: default

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp flag(value, _default) when is_boolean(value), do: value
  defp flag("true", _default), do: true
  defp flag("false", _default), do: false
  defp flag(_value, default), do: default
end
