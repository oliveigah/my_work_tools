defmodule MWTClient.Sandbox.Exchange do
  @moduledoc """
  What a request MWT read held, and what came back to the VM, kept with
  the request's activity events so the log can show both sides
  (`MWTClient.Storage.Journal.record_exchange/3`). Pure: the egress
  connection builds one, the server hides real values in it, the journal
  keeps it, and the activity page reads it back.

  Only requests MWT reads have one: a connection passed through as bytes
  (a tunnel) is TLS MWT never opened, so there is nothing to show of it.

    * **The request** is what the VM sent: placeholders as the VM wrote
      them, never the real value MWT puts in on the way out. Its body is
      what MWT read before deciding and what followed it, at most the
      limit.
    * **The response** is what reached the VM, read from the bytes MWT
      sent it (`capture/2`, `response/2`): the status line, the headers
      and the body, chunked framing and gzip or deflate undone, at most
      the limit of it. When MWT answered itself (a refusal, a denial, an
      answer it could not read), the response is that answer.
    * **The note**, when nothing came back, says why the request ended
      without an answer (`new/3`): MWT gave up waiting, the connection
      closed or failed, or MWT's connection for it ended first, which keeps
      the request only as MWT read it before deciding.

  The limit is how much of each body the log keeps, your setting
  (`MWTClient.Sandbox.Settings`, `log_body_kib`): `body_limit/0` (64 KiB)
  unless you change it, 0 for heads only.

  A body that isn't text (UTF-8 without control characters) is kept as
  bytes, and shown as such. What
  is cut says how long it was, when its headers said.
  """

  @body_limit 64 * 1024
  @head_limit 64 * 1024

  @typedoc "One side's body: the bytes kept, how many there were, whether it was cut."
  @type body :: %{
          data: binary() | nil,
          bytes: non_neg_integer() | nil,
          cut?: boolean(),
          note: String.t() | nil
        }

  @type request :: %{
          required(:method) => String.t(),
          required(:host) => String.t(),
          required(:path) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => body(),
          optional(:plain?) => true,
          optional(:ip) => String.t()
        }

  @type response :: %{
          status: non_neg_integer() | nil,
          reason: String.t() | nil,
          headers: [{String.t(), String.t()}],
          body: body(),
          by_mwt?: boolean(),
          note: String.t() | nil
        }

  @type t :: %{
          required(:request) => request(),
          required(:response) => response() | nil,
          optional(:note) => String.t()
        }

  @typedoc "The bytes sent to the VM so far, the first of them kept, at most `limit` of a body."
  @opaque capture :: %{
            kept: iodata(),
            size: non_neg_integer(),
            seen: non_neg_integer(),
            limit: non_neg_integer()
          }

  @doc "The most of a body kept, in bytes, unless you set another limit."
  @spec body_limit() :: pos_integer()
  def body_limit, do: @body_limit

  @doc """
  An exchange: `request`, and `response` or nil when nothing came back,
  then with `note` saying why it ended so. A response says its own note.
  """
  @spec new(request(), response() | nil, String.t() | nil) :: t()
  def new(request, nil, note) when is_binary(note),
    do: %{request: request, response: nil, note: note}

  def new(request, response, _note), do: %{request: request, response: response}

  @doc "A fresh id, which ties an exchange to the events of its request."
  @spec new_id() :: String.t()
  def new_id, do: "exchange-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @doc """
  The request as the VM sent it: `method`, `host`, `path`, `headers` and
  its `body`, at most `limit` bytes of it kept.
  """
  @spec request(map(), non_neg_integer()) :: request()
  def request(
        %{method: method, host: host, path: path, headers: headers} = request,
        limit \\ @body_limit
      ) do
    kept = %{
      method: method,
      host: host,
      path: path,
      headers: headers,
      body: body(Map.get(request, :body, ""), headers, limit)
    }

    # One that came as plain HTTP says so, and to which address.
    if Map.get(request, :plain?),
      do: Map.merge(kept, %{plain?: true, ip: request.ip}),
      else: kept
  end

  ## The response, as the bytes went to the VM

  @doc "Nothing sent to the VM yet; at most `limit` bytes of its body to keep."
  @spec capture(non_neg_integer()) :: capture()
  def capture(limit \\ @body_limit), do: %{kept: [], size: 0, seen: 0, limit: limit}

  @doc "`bytes` sent to the VM: the first of them kept, all of them counted."
  @spec capture(capture(), iodata()) :: capture()
  def capture(%{size: size, seen: seen} = capture, bytes) do
    length = IO.iodata_length(bytes)
    room = @head_limit + Map.get(capture, :limit, @body_limit) - size

    cond do
      length == 0 ->
        capture

      room <= 0 ->
        %{capture | seen: seen + length}

      length <= room ->
        %{capture | kept: [capture.kept, bytes], size: size + length, seen: seen + length}

      true ->
        part = binary_part(IO.iodata_to_binary(bytes), 0, room)
        %{capture | kept: [capture.kept, part], size: size + room, seen: seen + length}
    end
  end

  @doc """
  The response read from what went to the VM, or nil when nothing did.
  `note` says how it ended when that matters: cut by MWT, the connection
  closed early.
  """
  @spec response(capture(), String.t() | nil) :: response() | nil
  def response(%{seen: 0}, _note), do: nil

  def response(%{kept: kept, seen: seen} = capture, note) do
    data = IO.iodata_to_binary(kept)

    case final_head(data) do
      {:ok, status, reason, headers, rest} ->
        body = body(rest, headers, Map.get(capture, :limit, @body_limit))
        cut? = seen > byte_size(data) or body.cut?
        bytes = if cut? and is_nil(declared_length(headers)), do: nil, else: body.bytes

        %{
          status: status,
          reason: reason,
          headers: headers,
          body: %{body | cut?: cut?, bytes: bytes},
          by_mwt?: false,
          note: note
        }

      :error ->
        %{
          status: nil,
          reason: nil,
          headers: [],
          body: %{data: nil, bytes: seen, cut?: true, note: "Not readable as HTTP"},
          by_mwt?: false,
          note: note
        }
    end
  end

  @doc """
  An answer read as its parts rather than as bytes (an HTTP/2 stream's): its
  status and headers, `kept` the start of its body as it came (at most
  `limit` bytes of it), out of `seen` bytes in all.
  """
  @spec answer(
          non_neg_integer(),
          [{String.t(), String.t()}],
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          String.t() | nil
        ) ::
          response()
  def answer(status, headers, kept, seen, limit, note) do
    body = body(kept, headers, limit)
    cut? = seen > byte_size(kept) or body.cut?

    %{
      status: status,
      reason: reason(status),
      headers: headers,
      body: %{
        body
        | cut?: cut?,
          bytes: if(cut? and is_nil(declared_length(headers)), do: nil, else: body.bytes)
      },
      by_mwt?: false,
      note: note
    }
  end

  defp reason(status) do
    Plug.Conn.Status.reason_phrase(status)
  rescue
    ArgumentError -> nil
  end

  @doc "MWT's own answer, sent instead of the host's: a status and a JSON body."
  @spec mwt_answer(non_neg_integer(), binary()) :: response()
  def mwt_answer(status, json) do
    %{
      status: status,
      reason: Plug.Conn.Status.reason_phrase(status),
      headers: [{"content-type", "application/json"}],
      body: %{data: json, bytes: byte_size(json), cut?: false, note: nil},
      by_mwt?: true,
      note: "Answered by MWT; the request did not go out."
    }
  end

  @doc """
  Every text in the exchange (its path, header values and bodies) passed
  through `fun`: how the server hides real values before it is kept.
  """
  @spec redact(t(), (binary() -> binary())) :: t()
  def redact(%{request: request, response: response} = exchange, fun) do
    %{
      exchange
      | request: %{
          request
          | path: fun.(request.path),
            headers: redact_headers(request.headers, fun),
            body: redact_body(request.body, fun)
        },
        response:
          response &&
            %{
              response
              | headers: redact_headers(response.headers, fun),
                body: redact_body(response.body, fun)
            }
    }
  end

  defp redact_headers(headers, fun), do: for({name, value} <- headers, do: {name, fun.(value)})

  defp redact_body(%{data: data} = body, fun) when is_binary(data), do: %{body | data: fun.(data)}
  defp redact_body(body, _fun), do: body

  ## As JSON, for the clipboard

  @doc """
  The exchange as a JSON-ready map: headers as an object (a name sent twice
  keeps both values, in a list), a JSON body as JSON, other text as text,
  bytes as base64.
  """
  @spec to_json(t()) :: map()
  def to_json(%{request: request, response: response} = exchange) do
    json = %{
      "request" =>
        %{
          "method" => request.method,
          "url" =>
            if(Map.get(request, :plain?), do: "http://", else: "https://") <>
              request.host <> request.path,
          "headers" => headers_json(request.headers)
        }
        |> Map.merge(body_json(request.body, request.headers)),
      "response" =>
        response &&
          %{
            "status" => response.status,
            "reason" => response.reason,
            "headers" => headers_json(response.headers),
            "answered_by" => if(response.by_mwt?, do: "MWT", else: request.host),
            "note" => response.note
          }
          |> Map.merge(body_json(response.body, response.headers))
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }

    case exchange do
      %{note: note} when is_binary(note) -> Map.put(json, "note", note)
      _none -> json
    end
  end

  defp headers_json(headers) do
    headers
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn
      {name, [value]} -> {name, value}
      {name, values} -> {name, values}
    end)
  end

  defp body_json(%{data: nil} = body, _headers),
    do: %{"body" => nil, "body_bytes" => body.bytes, "body_note" => body.note}

  defp body_json(%{data: data} = body, headers) do
    {key, value} =
      cond do
        not text?(data) -> {"body_base64", Base.encode64(data)}
        json = json?(headers) && whole_json(data, body) -> {"body", json}
        true -> {"body", data}
      end

    %{key => value, "body_bytes" => body.bytes, "body_truncated" => body.cut?}
    |> then(&if(body.note, do: Map.put(&1, "body_note", body.note), else: &1))
  end

  @doc """
  The body as it reads best: pretty JSON when it is whole JSON, the text as
  it is otherwise; `:binary` for bytes that aren't text, nil for no body.
  """
  @spec readable(body(), [{String.t(), String.t()}]) :: String.t() | :binary | nil
  def readable(%{data: nil}, _headers), do: nil
  def readable(%{data: ""}, _headers), do: nil

  def readable(%{data: data} = body, headers) do
    cond do
      not text?(data) -> :binary
      json = json?(headers) && whole_json(data, body) -> Jason.encode!(json, pretty: true)
      true -> data
    end
  end

  # UTF-8 with no control characters but tabs and line ends: text to read.
  defp text?(data), do: String.valid?(data) and not (data =~ ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)

  defp json?(headers) do
    Enum.any?(headers, fn {name, value} ->
      name == "content-type" and String.contains?(String.downcase(value), "json")
    end)
  end

  defp whole_json(_data, %{cut?: true}), do: nil

  defp whole_json(data, _body) do
    case Jason.decode(data) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  ## Bodies

  # A body as its headers frame it: chunks joined, gzip or deflate undone,
  # at most `limit` kept.
  defp body(raw, headers, limit) do
    declared = declared_length(headers)
    {raw, framing_cut?} = unchunk(raw, headers)

    case decode(raw, header(headers, "content-encoding"), limit) do
      {:ok, data, decode_cut?} ->
        kept = binary_part(data, 0, min(byte_size(data), limit))

        cut? =
          framing_cut? or decode_cut? or byte_size(data) > limit or
            (declared != nil and byte_size(raw) < declared)

        %{
          data: kept,
          bytes: declared || if(not cut?, do: byte_size(data)),
          cut?: cut?,
          note: nil
        }

      {:unknown, encoding} ->
        %{
          data: nil,
          bytes: declared || byte_size(raw),
          cut?: false,
          note: "#{encoding}-encoded, which MWT doesn't decode"
        }
    end
  end

  defp declared_length(headers) do
    with value when is_binary(value) <- header(headers, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  defp unchunk(raw, headers) do
    chunked? =
      case header(headers, "transfer-encoding") do
        nil -> false
        value -> value |> String.downcase() |> String.contains?("chunked")
      end

    if chunked?, do: dechunk(raw, []), else: {raw, false}
  end

  # The chunks' data, up to the last chunk or as far as the bytes go.
  defp dechunk(data, acc) do
    with [line, rest] <- :binary.split(data, "\r\n"),
         {size, _extension} <- line |> String.trim() |> Integer.parse(16) do
      cond do
        size == 0 ->
          {IO.iodata_to_binary(Enum.reverse(acc)), false}

        byte_size(rest) >= size ->
          <<chunk::binary-size(size), more::binary>> = rest
          dechunk(String.replace_prefix(more, "\r\n", ""), [chunk | acc])

        true ->
          {IO.iodata_to_binary(Enum.reverse([rest | acc])), true}
      end
    else
      _ -> {IO.iodata_to_binary(Enum.reverse(acc)), data != ""}
    end
  end

  defp decode(raw, nil, _limit), do: {:ok, raw, false}

  defp decode(raw, encoding, limit) do
    case String.downcase(String.trim(encoding)) do
      "identity" -> {:ok, raw, false}
      "gzip" -> inflate(raw, 31, limit)
      "x-gzip" -> inflate(raw, 31, limit)
      "deflate" -> with :error <- inflate(raw, 15, limit), do: inflate(raw, -15, limit)
      other -> {:unknown, other}
    end
    |> case do
      :error -> {:unknown, encoding}
      result -> result
    end
  end

  # At most the limit inflated, however far the bytes would go: a small
  # body can stand for a huge one.
  defp inflate("", _window, _limit), do: {:ok, "", false}

  defp inflate(raw, window, limit) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, window)
      inflating(z, :zlib.safeInflate(z, raw), [], 0, limit)
    rescue
      _error -> :error
    catch
      _kind, _reason -> :error
    after
      :zlib.close(z)
    end
  end

  defp inflating(z, {:continue, out}, acc, size, limit) do
    size = size + IO.iodata_length(out)

    if size > limit,
      do: {:ok, IO.iodata_to_binary(Enum.reverse([out | acc])), true},
      else: inflating(z, :zlib.safeInflate(z, []), [out | acc], size, limit)
  end

  defp inflating(_z, {:finished, out}, acc, _size, _limit),
    do: {:ok, IO.iodata_to_binary(Enum.reverse([out | acc])), false}

  ## Heads

  # The final head: 1xx answers before it (103 Early Hints) are skipped,
  # but 101 Switching Protocols is final.
  defp final_head(data) do
    with [head, rest] <- :binary.split(data, "\r\n\r\n"),
         true <- byte_size(head) <= @head_limit,
         {:ok, status, reason, headers} <- read_head(head) do
      if status in 100..199 and status != 101,
        do: final_head(rest),
        else: {:ok, status, reason, headers, rest}
    else
      _ -> :error
    end
  end

  defp read_head(head) do
    [line | lines] = String.split(head, "\r\n")

    with [status | reason] <-
           Regex.run(~r/\AHTTP\/1\.[01] ([0-9]{3})(?: ([^\r\n]*))?\z/, line,
             capture: :all_but_first
           ),
         {:ok, headers} <- read_headers(lines, []) do
      {:ok, String.to_integer(status), List.first(reason), headers}
    else
      _ -> :error
    end
  end

  defp read_headers([], acc), do: {:ok, Enum.reverse(acc)}

  defp read_headers([line | rest], acc) do
    case String.split(line, ":", parts: 2) do
      [name, value] when name != "" ->
        read_headers(rest, [{String.downcase(String.trim(name)), String.trim(value)} | acc])

      _ ->
        :error
    end
  end
end
