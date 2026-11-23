defmodule MWTClient.Sandbox.Egress.RequestHead do
  @moduledoc """
  What a request's head must be for MWT to pass it on, whichever HTTP
  carried it (`Driver.Http1`, `Driver.Http2`). Pure.

  MWT judges a request by what it read, and the host must act on the same
  thing, so a head two parsers could read two ways doesn't go out: its
  target is a path in visible ASCII, it names its method once (no
  override), it says once how long its body is, it names the host the
  connection was encrypted for, and each of its fields is a token's name
  with a value of visible bytes, spaces and tabs. TRACE has the host send
  the request back, real value included; CONNECT would make the host a
  tunnel MWT can't read.

  Each driver reads its own framing (HTTP/1.1's lines, HTTP/2's header
  blocks and pseudo-headers) and asks these of what it read, so a rule
  holds the same over both.
  """

  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  @field_value ~r/\A[\t\x20-\x7e\x80-\xff]*\z/
  @overrides ~w(x-http-method-override x-http-method x-method-override)

  @typedoc "Why MWT refuses a head: the HTTP status, MWT's code, and words for people."
  @type refusal :: {:refuse, 100..599, String.t(), String.t()}

  @doc "Whether `text` is a token: a method, or a field's name."
  @spec token?(String.t()) :: boolean()
  def token?(text), do: text =~ @token

  @doc """
  Whether `value` is a field's value as HTTP says one is: visible bytes,
  spaces and tabs. No CR, LF, NUL or other control: where two parsers
  split a field differently, one of them reads a field the other didn't.
  """
  @spec field_value?(String.t()) :: boolean()
  def field_value?(value), do: value =~ @field_value

  @doc "A field's value with the spaces and tabs around it dropped, as HTTP reads it."
  @spec trimmed(String.t()) :: String.t()
  def trimmed(value), do: String.replace(value, ~r/\A[ \t]+|[ \t]+\z/, "")

  @doc """
  Why a head with this method, target and fields (names in lower case)
  can't go, or nil: what both HTTP versions refuse alike. A refused
  method (`405`), a method override, a target that isn't a path in
  visible ASCII, or a `Content-Length` said twice or not as a number
  (`400`).
  """
  @spec refusal(String.t(), String.t(), [{String.t(), String.t()}]) :: refusal() | nil
  def refusal(method, target, headers) do
    lengths = for {"content-length", value} <- headers, do: value

    cond do
      method in ["TRACE", "CONNECT"] ->
        {:refuse, 405, "mwt_method_refused", "MWT does not pass on #{method} requests."}

      # MWT would judge, and an allowance match, the method it reads while
      # the host carries out another.
      Enum.any?(headers, fn {name, _} -> name in @overrides end) ->
        {:refuse, 400, "mwt_bad_request",
         "A request says its method once: MWT doesn't pass on a method override."}

      not (String.starts_with?(target, "/") or (method == "OPTIONS" and target == "*")) ->
        {:refuse, 400, "mwt_bad_request", "The request target must be a path."}

      # What HTTP allows in a target, and what an approval can show as it is.
      not (target =~ ~r/\A[\x21-\x7e]+\z/) ->
        {:refuse, 400, "mwt_bad_request",
         "The request target must be visible ASCII: percent-encode anything else."}

      length(lengths) > 1 ->
        {:refuse, 400, "mwt_bad_request",
         "A request says how long its body is once: Content-Length or Transfer-Encoding."}

      lengths != [] and not (hd(lengths) =~ ~r/\A[0-9]+\z/) ->
        {:refuse, 400, "mwt_bad_request", "Content-Length must be a number."}

      true ->
        nil
    end
  end

  @doc """
  Whether `host`, as the request names it, is another than the
  connection's: its TLS name `name`, with its port or none. A request
  that says "github" to MWT must not go somewhere else.
  """
  @spec misdirected?(String.t(), String.t(), :inet.port_number()) :: boolean()
  def misdirected?(host, name, port), do: String.downcase(host) not in [name, "#{name}:#{port}"]
end
