defmodule MWTClient.Sandbox.SavedRequest do
  @moduledoc """
  A request action's request: one HTTP request MWT sends itself, with its
  credential's real value, when an agent calls the action by id with a
  value for each of its parameters. The VM never holds the value, and never
  chooses where it goes or what is sent beyond the values.

  Its template is a `method`, a `url`, fixed `headers` and a JSON `body`:

    * **The URL** is `https://` to a host, written out; reaching it takes a
      grant over its network, as any request does. Parameters go in the
      path or the query, as `$NAME` or
      `${NAME}`, never in the host. A value is percent-encoded for where it
      sits: a word keeps its `/` in the path, so `$REPO` can be
      `owner/name`; anything else is encoded whole.
    * **Headers** are fixed: no parameters. `{token}` stands for the grant's
      credential's real value, where it goes (`Authorization: Bearer
      {token}`). The values its adapter makes from it may stand there too:
      `{id_token}`, the ID token its login mint prints, for a Google login;
      `{signed_jwt}`, a JWT signed as the action's one account
      (`Grant.signs_as`), or `{signed_jwt:ACCOUNT}` naming one of its
      accounts, with the call's URL, without its query, as `aud`
      (`MWTClient.Sandbox.Adapter.Google.sign_jwt/4`). At least one header
      carries one of them.
    * **The body**, when there is one, is JSON. A parameter in it is a whole
      string value, `"$TITLE"`, never part of a longer one: the value goes
      in as a JSON value, encoded, so it can't change the shape of the body
      or the meaning of a query written inside a string. A number parameter
      that is a whole value goes in as a number.

  `errors/3` checks a template, `build/2` makes the request a call sends,
  `check/4` an ask into what its approval shows, and `send/4`, the only
  function here that leaves the machine, sends it: no redirects followed,
  no retries, the answer's body kept raw, with the value written out of it
  wherever the service echoed it back.
  """

  alias MWTClient.Sandbox.{Approval, Grant, HostCommand, Param, Shown}

  @methods ~w(GET POST PUT PATCH DELETE)
  @token "{token}"
  @id_token "{id_token}"
  @signed_jwt ~r/\{signed_jwt(?::([^}\s]+))?\}/
  @max_template 16 * 1024
  @keep 256 * 1024
  @default_timeout 30
  @max_timeout 300

  @ref ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/
  @header_name ~r/\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/
  # Headers the HTTP client writes itself.
  @managed ~w(host content-length transfer-encoding connection upgrade te)

  @type call :: %{
          method: String.t(),
          url: String.t(),
          host: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t() | nil
        }

  @doc "The methods a request action can send."
  @spec methods() :: [String.t()]
  def methods, do: @methods

  @doc "What stands for the grant's real value in a header."
  @spec token_mark() :: String.t()
  def token_mark, do: @token

  @doc "The time limit when a call names none, and the longest one allowed, in seconds."
  @spec timeouts() :: {pos_integer(), pos_integer()}
  def timeouts, do: {@default_timeout, @max_timeout}

  @doc """
  Headers from text, one a line, `Name: value`.

      iex> MWTClient.Sandbox.SavedRequest.headers("Authorization: Bearer {token}\\nAccept: application/json")
      [{"Authorization", "Bearer {token}"}, {"Accept", "application/json"}]
  """
  @spec headers(String.t() | nil) :: [{String.t(), String.t()}]
  def headers(nil), do: []

  def headers(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> {String.trim(name), String.trim(value)}
        [name] -> {String.trim(name), ""}
      end
    end)
  end

  @doc "Headers as lines, the way `headers/1` reads them."
  @spec header_lines([{String.t(), String.t()}]) :: String.t()
  def header_lines(headers), do: Enum.map_join(headers, "\n", fn {k, v} -> "#{k}: #{v}" end)

  @doc """
  The headers a request action starts with for a token grant made from
  `preset`: where that service takes the token, and what it asks clients to
  send.
  """
  @spec default_headers(atom() | nil) :: String.t()
  def default_headers(:github),
    do:
      "Authorization: Bearer {token}\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28"

  def default_headers(:hex), do: "Authorization: {token}\nAccept: application/json"
  def default_headers(_preset), do: "Authorization: Bearer {token}\nAccept: application/json"

  @doc """
  What is wrong with a request action's template, by field: its `method`,
  `url`, `headers` and `body` (nil or blank for none), against its
  parameters and `over`, the action with its credential's fields
  (`MWTClient.Sandbox.Credential.attach/2`), nil when it names none MWT
  has. It may send to any host: reaching it is a network grant's to give.
  """
  @spec errors(map(), [Param.t()], Grant.t() | nil) :: %{atom() => String.t()}
  def errors(template, params, over) do
    names = MapSet.new(params, & &1.name)
    body = blank_to_nil(template[:body])

    [
      {:credential, credential_error(over)},
      {:method, method_error(template[:method], body)},
      {:url, url_error(template[:url] || "", names)},
      {:headers, headers_error(template[:headers] || [], names, over)},
      {:body, body_error(body, names)},
      {:params, unused_error(params, template[:url] || "", body)}
    ]
    |> Enum.reject(fn {_field, error} -> is_nil(error) end)
    |> Map.new()
  end

  defp credential_error(%Grant{credential: id}) when is_binary(id), do: nil
  defp credential_error(_other), do: "A request action sends with a credential: pick one."

  defp method_error(method, body) do
    cond do
      method not in @methods ->
        "Pick one of #{Enum.join(@methods, ", ")}."

      method == "GET" and body != nil ->
        "A GET sends no body. Leave the body empty, or pick POST."

      true ->
        nil
    end
  end

  defp url_error(url, names) do
    {authority, _rest} = split_authority(url)

    cond do
      url == "" ->
        "Write the URL it sends to, starting with https://."

      byte_size(url) > @max_template ->
        "The URL is too long."

      Shown.hidden(url) != [] ->
        "The URL has characters that don't show (#{Enum.join(Shown.hidden(url), ", ")})."

      not String.starts_with?(String.downcase(url), "https://") ->
        "It sends over HTTPS only: start the URL with https://."

      String.contains?(authority, "$") ->
        "The host is fixed: a parameter goes in the path or the query, after the host."

      String.contains?(url, "#") ->
        "Leave out the # part: it never reaches the service."

      unknown(url, names) != [] ->
        "#{Enum.join(unknown(url, names), ", ")} isn't a parameter: list it below, or take it out."

      true ->
        host_error(authority) || shape_error(url)
    end
  end

  defp host_error(authority) do
    {host, port} =
      case String.split(authority, ":", parts: 2) do
        [host, port] -> {host, port}
        [host] -> {host, nil}
      end

    cond do
      String.contains?(authority, "@") ->
        "Leave the user and password out of the URL: the token goes in a header."

      port not in [nil, "443"] ->
        "It sends to the usual HTTPS port only: leave :#{port} out."

      host == "" or String.starts_with?(host, "*") ->
        "Write the host out in full, such as api.github.com."

      true ->
        nil
    end
  end

  defp shape_error(url) do
    case URI.new(Regex.replace(@ref, url, "x")) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> nil
      _other -> "That is not a URL MWT can send to."
    end
  end

  defp headers_error(headers, names, over) do
    Enum.find_value(headers, fn {name, value} ->
      cond do
        not Regex.match?(@header_name, name) ->
          "#{name}: a header is Name: value, one a line."

        String.downcase(name) in @managed ->
          "MWT writes #{name} itself: take it out."

        Shown.hidden(name <> value) != [] ->
          "#{name} has characters that don't show."

        Enum.any?(refs(value), &MapSet.member?(names, &1)) ->
          "Headers are fixed: a parameter goes in the URL or the body, not in #{name}."

        true ->
          nil
      end
    end) || marks_error(headers, over)
  end

  # Where the values go, and whether the credential can make each one
  # named, signing as the accounts the action names (`signs_as`).
  defp marks_error(headers, over) do
    needs = needs(headers)

    cond do
      not (needs.token or needs.id_token or needs.accounts != []) ->
        "Say where the token goes, as #{@token}, such as Authorization: Bearer #{@token}. Without it, the request needs no grant."

      needs.id_token and not google?(over) ->
        "#{@id_token} is the ID token a Google login's mint prints: this credential has none."

      needs.accounts != [] and not google?(over) ->
        "{signed_jwt} is signed by Google as an account the action names: this credential isn't Google's."

      bad = Enum.find(needs.accounts, &(not signs?(over, &1))) ->
        account_error(bad, signs_as(over))

      true ->
        nil
    end
  end

  defp account_error(:one, []),
    do: "{signed_jwt} needs the action to name the account it signs as (Signs as, on its form)."

  defp account_error(:one, _accounts),
    do: "The action signs as more than one account: name one, as {signed_jwt:ACCOUNT}."

  defp account_error(account, _accounts),
    do: "#{account} isn't an account the action signs as."

  defp google?(%Grant{} = over),
    do: MWTClient.Sandbox.Adapter.of(over) == MWTClient.Sandbox.Adapter.Google

  defp google?(_none), do: false

  # `{signed_jwt}` without an account reads as the grant's only one.
  defp signs?(over, :one), do: match?([_], signs_as(over))
  defp signs?(over, account), do: account in signs_as(over)

  defp signs_as(%Grant{signs_as: accounts}), do: Enum.map(accounts || [], &String.downcase/1)
  defp signs_as(_none), do: []

  @doc """
  What a call's headers need filled in: the credential's value (`token`),
  its ID token (`id_token`), and the accounts to sign a JWT as
  (`accounts`), `:one` for `{signed_jwt}` without one named.

      iex> MWTClient.Sandbox.SavedRequest.needs([{"Authorization", "Bearer {signed_jwt}"}, {"X-User", "{id_token}"}])
      %{token: false, id_token: true, accounts: [:one]}
  """
  @spec needs([{String.t(), String.t()}]) :: %{
          token: boolean(),
          id_token: boolean(),
          accounts: [String.t() | :one]
        }
  def needs(headers) do
    values = Enum.map(headers, &elem(&1, 1))

    %{
      token: Enum.any?(values, &String.contains?(&1, @token)),
      id_token: Enum.any?(values, &String.contains?(&1, @id_token)),
      accounts:
        values
        |> Enum.flat_map(&Regex.scan(@signed_jwt, &1))
        |> Enum.map(fn
          [_all, account] -> String.downcase(account)
          [_all] -> :one
        end)
        |> Enum.uniq()
    }
  end

  @doc """
  The accounts a call signs as, `{signed_jwt}` read as the action's one
  account, or why it can't: the action no longer signs as one of them, as
  its form may have changed since the call was asked.
  """
  @spec accounts(call(), Grant.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def accounts(call, %Grant{} = action) do
    accounts =
      for account <- needs(call.headers).accounts do
        case {account, signs_as(action)} do
          {:one, [only]} -> only
          {:one, _none_or_many} -> nil
          {named, _accounts} -> named
        end
      end

    if Enum.all?(accounts, &(is_binary(&1) and &1 in signs_as(action))),
      do: {:ok, accounts},
      else: {:error, "#{action.name} no longer signs as the account this call names"}
  end

  @doc "The `aud` a JWT signed for a call names: its URL without the query."
  @spec audience(call()) :: String.t()
  def audience(%{url: url}), do: url |> String.split("?", parts: 2) |> hd()

  defp body_error(nil, _names), do: nil

  defp body_error(body, names) do
    cond do
      byte_size(body) > @max_template ->
        "The body is over #{div(@max_template, 1024)} KiB."

      Shown.hidden(body) != [] ->
        "The body has characters that don't show (#{Enum.join(Shown.hidden(body), ", ")})."

      true ->
        case Jason.decode(body) do
          {:ok, json} -> json_error(json, names)
          {:error, error} -> "The body is JSON, and this isn't: #{Exception.message(error)}"
        end
    end
  end

  defp json_error(%{} = map, names) do
    Enum.find_value(map, fn {key, value} ->
      if refs(key) != [],
        do: "A parameter can't be a key (#{key}): put it in a value.",
        else: json_error(value, names)
    end)
  end

  defp json_error(list, names) when is_list(list),
    do: Enum.find_value(list, &json_error(&1, names))

  defp json_error(text, names) when is_binary(text) do
    case refs(text) do
      [] ->
        nil

      found ->
        cond do
          Enum.any?(found, &(not MapSet.member?(names, &1))) ->
            "#{Enum.join(Enum.reject(found, &MapSet.member?(names, &1)), ", ")} isn't a parameter: list it below, or take it out."

          whole(text) == nil ->
            "A parameter in the body is a whole value, \"$#{hd(found)}\", not part of a longer text: " <>
              "the value goes in as it is, so inside other text it could change what that text means."

          true ->
            nil
        end
    end
  end

  defp json_error(_other, _names), do: nil

  defp unused_error(params, url, body) do
    used = MapSet.new(refs(url) ++ refs(body || ""))

    case Enum.reject(params, &MapSet.member?(used, &1.name)) do
      [] ->
        nil

      unused ->
        "The request doesn't use #{Enum.map_join(unused, ", ", & &1.name)}. " <>
          "Put it in the URL or the body as $#{hd(unused).name}, or take it off the list."
    end
  end

  # The names a text refers to, as `$NAME` or `${NAME}`.
  defp refs(text) do
    @ref
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn parts -> Enum.find(parts, &(&1 != "")) end)
  end

  defp unknown(text, names), do: text |> refs() |> Enum.reject(&MapSet.member?(names, &1))

  # The parameter a JSON string is, whole, or nil.
  defp whole(text) do
    case Regex.run(~r/\A(?:\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*))\z/, text,
           capture: :all_but_first
         ) do
      nil -> nil
      parts -> Enum.find(parts, &(&1 != ""))
    end
  end

  # `https://host[:port]` and what follows it.
  defp split_authority(url) do
    rest = String.replace(url, ~r/\A[A-Za-z][A-Za-z0-9+.-]*:\/\//, "")

    case Regex.run(~r/\A([^\/?#]*)(.*)\z/s, rest) do
      [_, authority, after_it] -> {authority, after_it}
      nil -> {rest, ""}
    end
  end

  @doc "The host a request action sends to."
  @spec host(Grant.t()) :: String.t()
  def host(%Grant{url: url}) do
    {authority, _rest} = split_authority(url || "")
    authority |> String.split(":") |> hd() |> String.downcase()
  end

  @doc """
  The request a call sends: the template with each value in its place,
  encoded for where it sits. `values` are checked already
  (`MWTClient.Sandbox.Param.check/2`). The headers keep `{token}`; only
  `send/4` puts the value there.
  """
  @spec build(Grant.t(), [{String.t(), String.t()}]) :: call()
  def build(%Grant{} = grant, values) do
    shapes = Map.new(grant.params, &{&1.name, &1.shape})
    given = Map.new(values)
    {start, path_and_query} = split_url(grant.url)

    {path, query} =
      case String.split(path_and_query, "?", parts: 2) do
        [path, query] -> {path, query}
        [path] -> {path, nil}
      end

    path = fill(path, given, fn name, value -> encode_path(value, shapes[name]) end)
    query = query && fill(query, given, fn _name, value -> encode(value) end)
    url = start <> path <> if(query, do: "?" <> query, else: "")

    %{
      method: grant.method,
      url: url,
      host: host(grant),
      headers: grant.headers,
      body: body(grant.body, given, shapes)
    }
  end

  defp split_url(url) do
    {authority, rest} = split_authority(url)
    {"https://" <> authority, rest}
  end

  defp fill(text, given, encode) do
    Regex.replace(@ref, text, fn _all, braced, bare ->
      name = if braced != "", do: braced, else: bare
      encode.(name, Map.fetch!(given, name))
    end)
  end

  # A word may hold `/`, so `owner/name` stays two segments; its shape
  # rules out `..` and a leading `/`, so it only goes deeper.
  defp encode_path(value, :word), do: URI.encode(value, &(URI.char_unreserved?(&1) or &1 == ?/))
  defp encode_path(value, _shape), do: encode(value)

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp body(nil, _given, _shapes), do: nil
  defp body("", _given, _shapes), do: nil

  defp body(template, given, shapes) do
    case String.trim(template) do
      "" -> nil
      text -> text |> Jason.decode!() |> put_values(given, shapes) |> Jason.encode!()
    end
  end

  defp put_values(%{} = map, given, shapes),
    do: Map.new(map, fn {key, value} -> {key, put_values(value, given, shapes)} end)

  defp put_values(list, given, shapes) when is_list(list),
    do: Enum.map(list, &put_values(&1, given, shapes))

  defp put_values(text, given, shapes) when is_binary(text) do
    case whole(text) do
      nil ->
        text

      name ->
        value = Map.fetch!(given, name)
        if shapes[name] == :number, do: String.to_integer(value), else: value
    end
  end

  defp put_values(other, _given, _shapes), do: other

  @doc """
  An agent's call, checked and described for its approval card: the shape
  `MWTClient.Sandbox.HostCommand.check/4` gives a command, with the
  request it sends as `call` and as text in `script`.
  """
  @spec check(map(), Grant.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, map()} | {:error, :no_reason | :bad_timeout}
  def check(ask, %Grant{} = grant, credential_name, values) do
    reason = ask |> Map.get(:reason) |> Shown.text() |> String.trim() |> String.slice(0, 1_000)
    agent = ask |> Map.get(:agent) |> Shown.text() |> String.trim() |> String.slice(0, 60)
    timeout = Map.get(ask, :timeout) || @default_timeout

    cond do
      reason == "" ->
        {:error, :no_reason}

      not (is_integer(timeout) and timeout in 1..@max_timeout) ->
        {:error, :bad_timeout}

      true ->
        call = build(grant, values)

        {:ok,
         %{
           script: text(call, credential_name),
           dir: nil,
           timeout: timeout,
           reason: reason,
           agent: if(agent == "", do: "An agent", else: agent),
           thread: Approval.thread(ask),
           title: title(call),
           values: values,
           call: call,
           pattern: "call " <> Approval.digest_text({grant.id, values, timeout}),
           facts: [
             {"Sent by", "MWT, from this machine, with #{credential_name}'s real value"},
             {"To", call.host},
             {"Time limit", HostCommand.seconds_words(timeout)}
           ],
           hints: []
         }}
    end
  end

  @doc "A call's title: its method, host and path, shortened."
  @spec title(call()) :: String.t()
  def title(%{method: method, url: url}) do
    short = String.replace_prefix(url, "https://", "")
    short = if String.length(short) > 90, do: String.slice(short, 0, 89) <> "…", else: short
    "#{method} #{short}"
  end

  @doc """
  A call as text, for its card, the log and the copy button: the request
  line, the headers with the value shown as the grant's name, and the body.
  """
  @spec text(call(), String.t()) :: String.t()
  def text(call, grant_name) do
    headers =
      Enum.map_join(call.headers, "\n", fn {name, value} ->
        "#{name}: #{shown_value(value, grant_name)}"
      end)

    body =
      case call.body do
        nil -> ""
        body -> "\n\n" <> (body |> Jason.decode!() |> Jason.encode!(pretty: true))
      end

    "#{call.method} #{call.url}\n#{headers}#{body}"
  end

  @doc "A header's value with each value it carries shown by what it is."
  @spec shown_value(String.t(), String.t()) :: String.t()
  def shown_value(value, grant_name) do
    value
    |> String.replace(@token, "[#{grant_name}'s token]")
    |> String.replace(@id_token, "[#{grant_name}'s ID token]")
    |> then(
      &Regex.replace(@signed_jwt, &1, fn
        _all, "" -> "[a JWT signed as #{grant_name}'s account]"
        _all, account -> "[a JWT signed as #{account}]"
      end)
    )
  end

  @doc """
  Sends a call with the real values in place of their marks: `values` is
  the credential's value (`token`, for `{token}`; a bare string is that
  alone), its ID token (`id_token`), and the JWTs signed for it (`jwts`,
  by account as written, `:one` for `{signed_jwt}`). It reports how it went
  in the shape a command's run does: `exit` 0 for a 2xx answer and 22 for
  any other (as `curl --fail`), 124 when it hit `timeout` seconds; the
  answer's `status`; its body as `output`, the first 256 KiB, with `cut`
  bytes dropped after them. Wherever the body holds one of the values, it
  is written out as what it is.

  The body is read as it comes, and no further than MWT keeps: the VM
  often has a say in what an answer holds. So `bytes` is the length the
  answer gave for its body, or, without one, what was read before MWT
  stopped.

  Only tests configure `config :mwt_client, MWTClient.Sandbox.SavedRequest,
  plug: …`, which answers instead of the service.
  """
  @spec send(call(), String.t() | map(), String.t(), pos_integer()) :: map()
  def send(call, value, grant_name, timeout) when is_binary(value),
    do: send(call, %{token: value}, grant_name, timeout)

  def send(call, %{} = values, grant_name, timeout) do
    jwts = Map.get(values, :jwts, %{})

    headers =
      Enum.map(call.headers, fn {name, header} ->
        filled =
          header
          |> replace_mark(@token, values[:token])
          |> replace_mark(@id_token, values[:id_token])
          |> then(
            &Regex.replace(@signed_jwt, &1, fn
              _all, "" -> jwts[:one] || ""
              _all, account -> jwts[String.downcase(account)] || ""
            end)
          )

        {name, filled}
      end)

    # Each real value with the words it is written out as, longest first,
    # so a value that holds another is written out whole.
    secrets =
      ([
         {values[:token], "[#{grant_name}'s token]"},
         {values[:id_token], "[#{grant_name}'s ID token]"}
       ] ++
         Enum.map(jwts, fn {account, jwt} ->
           {jwt,
            if(account == :one,
              do: "[a JWT signed as #{grant_name}'s account]",
              else: "[a JWT signed as #{account}]"
            )}
         end))
      |> Enum.filter(fn {real, _shown} -> is_binary(real) and real != "" end)
      |> Enum.sort_by(fn {real, _shown} -> -byte_size(real) end)

    longest = secrets |> Enum.map(&byte_size(elem(&1, 0))) |> Enum.max(fn -> 0 end)

    headers =
      if call.body && not Enum.any?(headers, &(String.downcase(elem(&1, 0)) == "content-type")),
        do: headers ++ [{"content-type", "application/json"}],
        else: headers

    options =
      [
        method: call.method,
        url: call.url,
        headers: headers,
        body: call.body,
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        receive_timeout: timeout * 1_000,
        connect_options: [timeout: min(timeout, 15) * 1_000],
        # A value that starts within what is kept ends within this.
        into: keeping(@keep + longest)
      ] ++ test_options()

    case Req.request(options) do
      {:ok, %Req.Response{status: status} = response} ->
        {read, size} = Req.Response.get_private(response, :mwt_body, {"", 0})
        body = written_out(read, secrets)
        kept = if byte_size(body) > @keep, do: binary_part(body, 0, @keep), else: body

        # How long the body is, the value written out as the name: all of
        # it was read, or, where MWT stopped reading, as long as the answer
        # said or at least what came.
        bytes =
          if size == byte_size(read),
            do: byte_size(body),
            else: max(length_of(response) || 0, size) + byte_size(body) - byte_size(read)

        %{
          exit: if(status in 200..299, do: 0, else: 22),
          status: status,
          output: String.replace_invalid(kept, "�"),
          bytes: bytes,
          cut: bytes - byte_size(kept),
          timed_out: false,
          error: nil
        }

      {:error, %{reason: :timeout}} ->
        %{exit: 124, status: nil, output: "", bytes: 0, cut: 0, timed_out: true, error: nil}

      {:error, error} ->
        message = error |> Exception.message() |> written_out(secrets)
        %{exit: nil, status: nil, output: "", bytes: 0, cut: 0, timed_out: false, error: message}
    end
  end

  defp replace_mark(header, _mark, nil), do: header
  defp replace_mark(header, mark, value), do: String.replace(header, mark, value)

  defp written_out(text, secrets),
    do: Enum.reduce(secrets, text, fn {real, shown}, acc -> String.replace(acc, real, shown) end)

  # Collects the body as it comes, up to `limit` bytes, counting what
  # arrives; reading stops there.
  defp keeping(limit) do
    fn {:data, data}, {request, response} ->
      {read, size} = Req.Response.get_private(response, :mwt_body, {"", 0})
      take = min(limit - byte_size(read), byte_size(data))
      read = read <> binary_part(data, 0, take)
      size = size + byte_size(data)
      response = Req.Response.put_private(response, :mwt_body, {read, size})

      if byte_size(read) >= limit,
        do: {:halt, {request, response}},
        else: {:cont, {request, response}}
    end
  end

  defp length_of(response) do
    with [length | _] <- Req.Response.get_header(response, "content-length"),
         {length, ""} <- Integer.parse(length) do
      length
    else
      _ -> nil
    end
  end

  defp test_options do
    case Application.get_env(:mwt_client, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end
end
