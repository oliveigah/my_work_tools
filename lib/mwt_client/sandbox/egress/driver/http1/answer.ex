defmodule MWTClient.Sandbox.Egress.Driver.Http1.Answer do
  @moduledoc """
  The answer to a request MWT passed on as the VM sent it, read only to
  know where it ends and whether its connection may carry the next
  request. Pure: bytes from upstream go in (`feed/2`), the same bytes come
  out, unchanged.

  An answer is its heads (any `1xx` before the final one, `103 Early
  Hints` say) and the final head's body, framed as `Framing.answer/3`
  says. Its connection is kept for the next request when the final head
  is HTTP/1.1, doesn't say `Connection: close`, and frames its body:
  otherwise the host ends it, or only its close tells where the answer
  ends.

  Nothing here refuses: the VM's client reads the answer, and MWT put
  nothing in the request to look for in it (`MWTClient.Sandbox.Egress.Driver.Http1.Response`
  reads the answers to the requests it did). A head MWT can't read, or one
  over 64 KiB, is passed on as it is, running until the close, and its
  connection isn't kept.
  """

  alias MWTClient.Sandbox.Egress.Driver.Http1.{Framing, Response}

  @head_limit 64 * 1024

  @derive {Inspect, only: [:phase, :keep?]}
  defstruct [:method, phase: :head, buffer: "", keep?: false, started?: false]

  @opaque t :: %__MODULE__{}

  @doc "The answer to a `method` request, none of it read yet."
  @spec new(String.t()) :: t()
  def new(method), do: %__MODULE__{method: method}

  @doc """
  The next bytes from upstream: `{:more, bytes, answer}`, the bytes to
  pass on now (a head is passed on once it is whole); or `{:done, bytes,
  beyond, keep?}` once the answer ended, `beyond` being what came after it
  and `keep?` whether its connection may carry the next request.
  """
  @spec feed(t(), binary()) ::
          {:more, iodata(), t()} | {:done, iodata(), binary(), boolean()}
  def feed(%__MODULE__{} = answer, data),
    do: step(%{answer | started?: answer.started? or data != ""}, data, [])

  @doc "Whether any byte of the answer has come."
  @spec started?(t()) :: boolean()
  def started?(%__MODULE__{started?: started?}), do: started?

  @doc """
  Upstream closed: what of the answer was held back (a head not whole),
  and whether the answer had ended as its framing said, or was cut short.
  An answer running until the close ends there.
  """
  @spec finish(t()) :: {:ended | :cut, iodata()}
  def finish(%__MODULE__{phase: :head, buffer: buffer, started?: started?}),
    do: {if(started?, do: :cut, else: :ended), buffer}

  def finish(%__MODULE__{phase: phase}),
    do: {if(Framing.until_close?(phase), do: :ended, else: :cut), []}

  defp step(%__MODULE__{phase: :head} = answer, data, out) do
    buffer = answer.buffer <> data

    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] when byte_size(head) <= @head_limit ->
        headed(%{answer | buffer: ""}, head, rest, out)

      [_partial] when byte_size(buffer) <= @head_limit ->
        {:more, out, %{answer | buffer: buffer}}

      _too_large ->
        {:more, [out, buffer], %{answer | buffer: "", phase: :close, keep?: false}}
    end
  end

  defp step(%__MODULE__{} = answer, data, out) do
    case Framing.feed(answer.phase, data) do
      {:more, bytes, framing} -> {:more, [out, bytes], %{answer | phase: framing}}
      {:done, bytes, beyond} -> {:done, [out, bytes], beyond, answer.keep?}
      # Framing that stops making sense is passed on until the close.
      :error -> {:more, [out, data], %{answer | phase: :close, keep?: false}}
    end
  end

  defp headed(answer, head, rest, out) do
    out = [out, head, "\r\n\r\n"]

    case Response.read_head(head) do
      {:ok, status, _headers} when status in 100..199 and status != 101 ->
        step(answer, rest, out)

      {:ok, status, headers} ->
        framing = Framing.answer(answer.method, status, headers)

        keep? =
          status != 101 and String.starts_with?(head, "HTTP/1.1 ") and
            not Framing.until_close?(framing) and not closes?(headers)

        step(%{answer | phase: framing, keep?: keep?}, rest, out)

      :error ->
        step(%{answer | phase: :close, keep?: false}, rest, out)
    end
  end

  defp closes?(headers) do
    Enum.any?(headers, fn {name, value} ->
      name == "connection" and
        value
        |> String.downcase()
        |> String.split(",")
        |> Enum.any?(&(String.trim(&1) == "close"))
    end)
  end
end
