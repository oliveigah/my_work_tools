defmodule MWTClient.Sandbox.StrictJson do
  @moduledoc """
  JSON from the VM, read only when it reads one way, as a request's head
  is (`MWTClient.Sandbox.Egress.Driver.Http1`): for what a card says and
  what *Allow similar* goes by.

  An object that names a key twice doesn't: JSON leaves which of the two
  counts to the parser. Jason keeps the first, the servers MWT passes
  requests to mostly the last (Ruby's, JavaScript's, Go's, Python's). A
  GraphQL body with two `query` keys would be shown, titled and allowed
  as its first document, and run as its second. So such JSON is not read:
  `:error`, as for JSON that doesn't parse, and whoever reads it treats it
  as a body it can't describe.
  """

  @doc """
  The JSON in `data`, with its objects as maps; `:error` when it doesn't
  parse, or when an object in it, at any depth, names a key twice.
  """
  @spec decode(binary()) :: {:ok, term()} | :error
  def decode(data) when is_binary(data) do
    case Jason.decode(data, objects: :ordered_objects) do
      {:ok, ordered} -> {:ok, plain(ordered)}
      {:error, _reason} -> :error
    end
  catch
    :twice -> :error
  end

  defp plain(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    if length(Enum.uniq(keys)) != length(keys), do: throw(:twice)
    Map.new(pairs, fn {key, value} -> {key, plain(value)} end)
  end

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value
end
