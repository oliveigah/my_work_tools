defmodule MWTClient.Sandbox.ParamSchema.Formats do
  @moduledoc """
  The JSON Schema formats MWT adds to the standard ones for a fixed call's
  parameters (`MWTClient.Sandbox.ParamSchema`), as `JSV` takes them:

    * `word`: letters, digits and `_ . - @ : +`, in parts joined by `/`;
      no part is `.` or `..`, none is empty, it starts with neither `/`
      nor `-`, and holds at most 200 bytes. A name, a branch, a path
      under the folder: it goes deeper, never up or to the root, and never
      reads as an option.

      iex> alias MWTClient.Sandbox.ParamSchema.Formats
      iex> Formats.word?("feature/login-v2")
      true
      iex> Enum.map(["a b", "../x", "/etc", "-rf", "a//b"], &Formats.word?/1)
      [false, false, false, false, false]
  """

  @behaviour JSV.FormatValidator

  @part ~r/\A[A-Za-z0-9_.@:+-]+\z/
  @max_word 200

  @impl true
  def supported_formats, do: ["word"]

  @impl true
  def applies_to_type?("word", data), do: is_binary(data)

  @impl true
  def validate_cast("word", data) do
    if word?(data), do: {:ok, data}, else: {:error, "it isn't a word"}
  end

  @doc "Whether `value` is a word (the moduledoc's)."
  @spec word?(String.t()) :: boolean()
  def word?(value) when is_binary(value) do
    byte_size(value) <= @max_word and not String.starts_with?(value, "-") and
      value
      |> String.split("/")
      |> Enum.all?(&(Regex.match?(@part, &1) and &1 not in [".", ".."]))
  end
end
