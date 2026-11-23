defmodule MWTClient.Sandbox.Egress.AnswerBody do
  @moduledoc """
  The body of an answer to a request MWT put a real value in, looked
  through for the value's forms on its way to the VM, whichever HTTP
  carries it (`Driver.Http1.Response`, `Driver.Http2`). Pure, but for the
  zlib stream an encoded body is decoded with.

    * **Not encoded**: the bytes go as they come, but those at the end that
      could start a form wait for what follows (`MWTClient.Sandbox.Egress.Scanner`):
      the caller lets them go when the stream pauses (`release/1`) or ends.
    * **gzip or deflate**: decoded a piece at a time for the look only, so
      a value compressed is found too, and the bytes go to the VM as they
      came. MWT asked for no encoding; a host may send one anyway.
    * **Any other encoding** (`br`, `zstd`, two at once): MWT can't read
      it, so the answer is refused rather than passed on (`encoding/1`).
  """

  alias MWTClient.Sandbox.Egress.Scanner
  alias MWTClient.Sandbox.Secrets

  @derive {Inspect, only: []}
  defstruct [:scanner, :inflate]

  @opaque t :: %__MODULE__{}

  @doc """
  How an answer with these headers (names in lower case) encodes its
  body: `{:ok, nil}` for none, `{:ok, :gzip}` or `{:ok, :deflate}`, or
  `:error` for one MWT can't decode.
  """
  @spec encoding([{String.t(), String.t()}]) :: {:ok, nil | :gzip | :deflate} | :error
  def encoding(headers) do
    case for({"content-encoding", value} <- headers, token <- tokens(value), do: token) do
      [] -> {:ok, nil}
      ["identity"] -> {:ok, nil}
      [gzip] when gzip in ["gzip", "x-gzip"] -> {:ok, :gzip}
      ["deflate"] -> {:ok, :deflate}
      _other -> :error
    end
  end

  @doc "A body encoded as `encoding/1` said, to be looked through for `echo`."
  @spec new(Secrets.t() | nil, nil | :gzip | :deflate) :: t()
  def new(echo, nil), do: %__MODULE__{scanner: Scanner.new(echo, hold: true)}

  def new(echo, encoding) do
    z = :zlib.open()
    # 31: gzip only; 47: zlib or gzip, told apart by their headers.
    :ok = :zlib.inflateInit(z, if(encoding == :gzip, do: 31, else: 47))
    %__MODULE__{scanner: Scanner.new(echo), inflate: z}
  end

  @doc """
  The body's next bytes as they came: `{:ok, bytes, body}`, the bytes that
  may go to the VM now; `{:found, label}` when a form of the value is in
  them, counting what came before; `:unreadable` for an encoded body that
  doesn't decode.
  """
  @spec feed(t(), binary()) :: {:ok, binary(), t()} | {:found, Secrets.label()} | :unreadable
  def feed(%__MODULE__{inflate: nil} = body, payload) do
    case Scanner.feed(body.scanner, payload) do
      {:ok, bytes, scanner} -> {:ok, bytes, %{body | scanner: scanner}}
      {:found, label} -> {:found, label}
    end
  end

  def feed(%__MODULE__{inflate: z} = body, payload) do
    case decoded(z, :zlib.safeInflate(z, payload), body.scanner) do
      {:ok, scanner} -> {:ok, payload, %{body | scanner: scanner}}
      other -> other
    end
  rescue
    ErlangError -> :unreadable
  end

  @doc "The bytes held back as the possible start of a form, let go: the stream paused or ended."
  @spec release(t()) :: {binary(), t()}
  def release(%__MODULE__{} = body) do
    {held, scanner} = Scanner.release(body.scanner)
    {held, %{body | scanner: scanner}}
  end

  @doc "Whether bytes are held back, waiting for what follows."
  @spec held?(t()) :: boolean()
  def held?(%__MODULE__{scanner: scanner}), do: Scanner.held?(scanner)

  # Inflated a piece at a time, each looked through as it comes, so an
  # answer that inflates to a lot is never held whole.
  defp decoded(z, {more, piece}, scanner) when more in [:continue, :finished] do
    case Scanner.feed(scanner, IO.iodata_to_binary(piece)) do
      {:ok, _bytes, scanner} ->
        if more == :continue,
          do: decoded(z, :zlib.safeInflate(z, []), scanner),
          else: {:ok, scanner}

      {:found, label} ->
        {:found, label}
    end
  end

  defp decoded(_z, _other, _scanner), do: :unreadable

  defp tokens(value) do
    value
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end
end
