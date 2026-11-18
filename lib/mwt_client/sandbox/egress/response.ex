defmodule MWTClient.Sandbox.Egress.Response do
  @moduledoc """
  The answer to a request MWT put a real value in, read as HTTP on its way
  back to the VM, so that none of the value reaches it. Pure: bytes from
  upstream go in (`feed/2`), bytes for the VM come out.

  A service may quote what it was sent: a header copied into its answer, an
  error page or a debug route echoing the request. So each form the value
  left in (`echo`, a `MWTClient.Sandbox.Secrets`) is looked for in the
  whole answer:

    * **every head**: `1xx` answers (`103 Early Hints`), the final head, a
      chunked body's trailers. The value is replaced with the placeholder.
    * **the body**, through its framing (`Content-Length`, chunked, or up to
      the close), with gzip and deflate decoded for the look only. Found,
      the answer is cut there, before any byte of the value goes
      (`{:cut, {:found, label}, bytes}`): replacing it would change the
      body's length. A chunked body is written out again in chunks of
      MWT's own, so a value split by the framing is held back like any
      other. Without encoding, the bytes that could start the value wait
      for what follows (`MWTClient.Sandbox.Egress.Scanner`); the caller
      lets them go when the stream pauses (`release/1`) or ends.
    * after `101 Switching Protocols`, the bytes that follow, the same way.

  What can't be read this way is refused, not passed on: a head over 64
  KiB, framing that doesn't parse, an encoding other than gzip or deflate
  (MWT asked for none). `{:refuse, message}` while nothing has gone to the
  VM, for a `502`; a cut after. Once the final answer is whole, the
  connection ends (`{:done, bytes}`): one request, one answer.
  """

  alias MWTClient.Sandbox.Egress.Scanner
  alias MWTClient.Sandbox.Secrets

  @head_limit 64 * 1024
  @line_limit 4096

  @derive {Inspect, only: [:phase, :sent?]}
  defstruct [
    :echo,
    :placeholder,
    :head_only?,
    :scanner,
    :inflate,
    phase: :head,
    buffer: "",
    sent?: false
  ]

  @opaque t :: %__MODULE__{}

  @type result ::
          {:more, iodata(), t()}
          | {:done, iodata()}
          | {:cut, {:found, Secrets.label()} | :unreadable, iodata()}
          | {:refuse, String.t()}

  @doc """
  The answer to a `method` request whose value goes by the forms in `echo`,
  to be replaced in heads by `placeholder`.
  """
  @spec new(String.t(), Secrets.t(), String.t()) :: t()
  def new(method, echo, placeholder),
    do: %__MODULE__{echo: echo, placeholder: placeholder, head_only?: method == "HEAD"}

  @doc "The next bytes from upstream."
  @spec feed(t(), binary()) :: result()
  def feed(%__MODULE__{} = response, data), do: step(response, data, [])

  @doc """
  The bytes held back as the possible start of the value, let go: the
  stream paused. What would complete the value is still looked for.
  """
  @spec release(t()) :: {iodata(), t()}
  def release(%__MODULE__{scanner: nil} = response), do: {[], response}

  def release(%__MODULE__{scanner: scanner} = response) do
    {held, scanner} = Scanner.release(scanner)
    response = %{response | scanner: scanner}
    {framed(response, held), sent(response, held)}
  end

  @doc "Whether bytes are held back, waiting for what follows."
  @spec held?(t()) :: boolean()
  def held?(%__MODULE__{scanner: nil}), do: false
  def held?(%__MODULE__{scanner: scanner}), do: Scanner.held?(scanner)

  @doc """
  Upstream closed. What was held back goes (it wasn't the value); a head
  cut short is unreadable.
  """
  @spec finish(t()) :: {:done, iodata()} | {:cut, :unreadable, iodata()} | {:refuse, String.t()}
  def finish(%__MODULE__{phase: :head, buffer: "", sent?: false}), do: {:done, []}

  def finish(%__MODULE__{phase: :head, buffer: "", sent?: true}),
    do: {:cut, :unreadable, []}

  def finish(%__MODULE__{phase: :head} = response),
    do: unreadable(response, [], "The answer ended inside its head.")

  def finish(%__MODULE__{} = response) do
    {held, _response} = release(response)
    {:done, held}
  end

  ## Steps

  defp step(%__MODULE__{phase: :head} = response, data, out) do
    buffer = response.buffer <> data

    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] when byte_size(head) <= @head_limit ->
        case read_head(head) do
          {:ok, status, headers} -> headed(response, head, status, headers, rest, out)
          :error -> unreadable(response, out, "MWT could not read the answer's head.")
        end

      [_head, _rest] ->
        unreadable(response, out, "The answer's head is over 64 KiB.")

      [_partial] when byte_size(buffer) > @head_limit ->
        unreadable(response, out, "The answer's head is over 64 KiB.")

      [_partial] ->
        {:more, out, %{response | buffer: buffer}}
    end
  end

  defp step(%__MODULE__{phase: {:length, left}} = response, data, out) do
    take = min(left, byte_size(data))

    with {:ok, bytes, response} <- body(response, binary_part(data, 0, take)) do
      out = [out, bytes]

      if take == left do
        {held, _response} = release(response)
        {:done, [out, held]}
      else
        {:more, out, %{response | phase: {:length, left - take}}}
      end
    else
      {:cut, reason, bytes} -> {:cut, reason, [out, bytes]}
    end
  end

  defp step(%__MODULE__{phase: :close} = response, data, out), do: flowing(response, data, out)
  defp step(%__MODULE__{phase: :raw} = response, data, out), do: flowing(response, data, out)

  defp step(%__MODULE__{phase: {:chunked, part}} = response, data, out),
    do: chunked(response, part, response.buffer <> data, out)

  defp flowing(response, data, out) do
    case body(response, data) do
      {:ok, bytes, response} -> {:more, [out, bytes], response}
      {:cut, reason, bytes} -> {:cut, reason, [out, bytes]}
    end
  end

  # A head, read: written out with the value replaced, then whatever
  # follows it. A final head whose body MWT couldn't read is refused before
  # it goes.
  defp headed(response, head, status, headers, rest, out) do
    written = [Secrets.replace(response.echo, head, response.placeholder), "\r\n\r\n"]

    cond do
      status == 101 ->
        response = %{
          response
          | buffer: "",
            sent?: true,
            phase: :raw,
            scanner: scanner(response.echo, nil)
        }

        step(response, rest, [out, written])

      status in 100..199 ->
        step(%{response | buffer: "", sent?: true, phase: :head}, rest, [out, written])

      true ->
        case framing(response, status, headers) do
          {:ok, :none, _encoding} ->
            {:done, [out, written]}

          {:ok, phase, encoding} ->
            response = %{
              response
              | buffer: "",
                sent?: true,
                phase: phase,
                scanner: scanner(response.echo, encoding),
                inflate: inflater(encoding)
            }

            if rest == "",
              do: {:more, [out, written], response},
              else: step(response, rest, [out, written])

          {:error, message} ->
            unreadable(response, out, message)
        end
    end
  end

  defp framing(response, status, headers) do
    codings = tokens(headers, "transfer-encoding")
    lengths = headers |> values("content-length") |> Enum.uniq()

    cond do
      response.head_only? or status in [204, 304] ->
        {:ok, :none, nil}

      encoding(tokens(headers, "content-encoding")) == :error ->
        {:error, "Its body is encoded in a way MWT doesn't decode (MWT asked for none)."}

      codings == ["chunked"] ->
        {:ok, {:chunked, :size}, elem(encoding(tokens(headers, "content-encoding")), 1)}

      codings != [] ->
        {:error, "Its body is sent in a way MWT doesn't read: #{Enum.join(codings, ", ")}."}

      lengths == [] ->
        {:ok, :close, elem(encoding(tokens(headers, "content-encoding")), 1)}

      match?([_], lengths) and hd(lengths) =~ ~r/\A[0-9]+\z/ ->
        case String.to_integer(hd(lengths)) do
          0 ->
            {:ok, :none, nil}

          length ->
            {:ok, {:length, length}, elem(encoding(tokens(headers, "content-encoding")), 1)}
        end

      true ->
        {:error, "Its length isn't one number."}
    end
  end

  defp encoding([]), do: {:ok, nil}
  defp encoding(["identity"]), do: {:ok, nil}
  defp encoding([gzip]) when gzip in ["gzip", "x-gzip"], do: {:ok, :gzip}
  defp encoding(["deflate"]), do: {:ok, :deflate}
  defp encoding(_other), do: :error

  defp scanner(echo, nil), do: Scanner.new(echo, hold: true)
  defp scanner(echo, _encoded), do: Scanner.new(echo)

  defp inflater(nil), do: nil

  defp inflater(encoding) do
    z = :zlib.open()
    # 31: gzip only; 47: zlib or gzip, told apart by their headers.
    :ok = :zlib.inflateInit(z, if(encoding == :gzip, do: 31, else: 47))
    z
  end

  ## Chunked bodies, written out again in chunks of MWT's own

  defp chunked(response, :size, buffer, out) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        case chunk_size(line) do
          {:ok, 0} -> chunked(response, :trailers, rest, out)
          {:ok, size} -> chunked(response, {:data, size}, rest, out)
          :error -> {:cut, :unreadable, out}
        end

      [_partial] when byte_size(buffer) > @line_limit ->
        {:cut, :unreadable, out}

      [_partial] ->
        waiting(response, :size, buffer, out)
    end
  end

  defp chunked(response, {:data, left}, buffer, out) do
    take = min(left, byte_size(buffer))
    <<payload::binary-size(take), rest::binary>> = buffer

    case body(response, payload) do
      {:ok, bytes, response} ->
        out = [out, bytes]

        if take == left,
          do: chunked(response, :crlf, rest, out),
          else: waiting(response, {:data, left - take}, rest, out)

      {:cut, reason, bytes} ->
        {:cut, reason, [out, bytes]}
    end
  end

  defp chunked(response, :crlf, "\r\n" <> rest, out), do: chunked(response, :size, rest, out)

  defp chunked(response, :crlf, buffer, out) when byte_size(buffer) < 2,
    do: waiting(response, :crlf, buffer, out)

  defp chunked(_response, :crlf, _buffer, out), do: {:cut, :unreadable, out}

  defp chunked(response, :trailers, "\r\n" <> _rest, out) do
    {held, _response} = release(response)
    {:done, [out, held, "0\r\n\r\n"]}
  end

  defp chunked(response, :trailers, buffer, out) do
    case :binary.split(buffer, "\r\n\r\n") do
      [trailers, _rest] when byte_size(trailers) <= @head_limit ->
        {held, _response} = release(response)

        {:done,
         [
           out,
           held,
           "0\r\n",
           Secrets.replace(response.echo, trailers, response.placeholder),
           "\r\n\r\n"
         ]}

      [_partial] when byte_size(buffer) <= @head_limit ->
        waiting(response, :trailers, buffer, out)

      _too_large ->
        {:cut, :unreadable, out}
    end
  end

  defp waiting(response, part, buffer, out),
    do: {:more, out, %{response | phase: {:chunked, part}, buffer: buffer}}

  defp chunk_size(line) do
    digits = line |> String.split(";", parts: 2) |> hd() |> String.trim()

    if digits =~ ~r/\A[0-9a-fA-F]{1,15}\z/,
      do: {:ok, String.to_integer(digits, 16)},
      else: :error
  end

  ## The body's bytes

  # Bytes of the body, as sent: looked through (decoded first when encoded),
  # and what may go to the VM given back, framed.
  defp body(%__MODULE__{inflate: nil} = response, payload) do
    case Scanner.feed(response.scanner, payload) do
      {:ok, bytes, scanner} ->
        response = %{response | scanner: scanner}
        {:ok, framed(response, bytes), sent(response, bytes)}

      {:found, label} ->
        {:cut, {:found, label}, []}
    end
  end

  defp body(%__MODULE__{inflate: z} = response, payload) do
    case decoded(z, :zlib.safeInflate(z, payload), response.scanner) do
      {:ok, scanner} ->
        response = %{response | scanner: scanner}
        {:ok, framed(response, payload), sent(response, payload)}

      {:found, label} ->
        {:cut, {:found, label}, []}

      :error ->
        {:cut, :unreadable, []}
    end
  rescue
    ErlangError -> {:cut, :unreadable, []}
  end

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

  defp decoded(_z, _other, _scanner), do: :error

  defp framed(_response, ""), do: []

  defp framed(%__MODULE__{phase: {:chunked, _}}, bytes),
    do: [Integer.to_string(byte_size(bytes), 16), "\r\n", bytes, "\r\n"]

  defp framed(_response, bytes), do: bytes

  defp sent(response, ""), do: response
  defp sent(response, _bytes), do: %{response | sent?: true}

  defp unreadable(%__MODULE__{sent?: false}, _out, message), do: {:refuse, message}
  defp unreadable(_response, out, _message), do: {:cut, :unreadable, out}

  ## Heads

  # A status line and `name: value` lines; a line folded onto the one
  # before, or without a colon, is not read.
  defp read_head(head) do
    [line | lines] = String.split(head, "\r\n")

    with [_, status] <- Regex.run(~r/\AHTTP\/1\.[01] ([0-9]{3})(?: [^\r\n]*)?\z/, line),
         {:ok, headers} <- read_headers(lines, []) do
      {:ok, String.to_integer(status), headers}
    else
      _ -> :error
    end
  end

  defp read_headers([], acc), do: {:ok, Enum.reverse(acc)}

  defp read_headers([line | rest], acc) do
    case String.split(line, ":", parts: 2) do
      [name, value] when name != "" ->
        if String.trim(name) == name,
          do: read_headers(rest, [{String.downcase(name), String.trim(value)} | acc]),
          else: :error

      _ ->
        :error
    end
  end

  defp values(headers, name), do: for({^name, value} <- headers, do: value)

  defp tokens(headers, name) do
    headers
    |> values(name)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end
end
