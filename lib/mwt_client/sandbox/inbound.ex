defmodule MWTClient.Sandbox.Inbound do
  @moduledoc """
  What MWT moves into the VM, looked through before it goes: the output of
  a command run on this machine, a request action's answer, the results
  of MWT's tools. `MWTClient.Sandbox.Shown` covers every way into MWT;
  this covers the ways out to the VM (see "What enters the VM" in
  `docs/agent_sandbox.md`).

  Pure. It looks for two things:

    * **real values**: every token grant's value at hand, in every form
      MWT knows (`MWTClient.Sandbox.Secrets.forms/1`);
    * **credential shapes**: a PEM private-key block, a three-segment JWT,
      and a short list of well-known prefixes followed by a long token
      (`shapes/0`). Prefix and length, never a regex you write.

  A finding says what it looked like and on which line, never the text it
  matched: that holds the credential.
  """

  alias MWTClient.Sandbox.Secrets

  @type what :: {:value, String.t()} | {:shape, String.t()}
  @type finding :: %{what: what(), line: pos_integer()}

  # {what it looks like, prefixes, how many token characters must follow at
  # least, which characters count}.
  @shapes [
    {"a GitHub token", ~w(ghp_ gho_ ghu_ ghs_ ghr_), 30, :token},
    {"a GitHub token", ~w(github_pat_), 40, :token},
    {"a GitLab token", ~w(glpat-), 20, :token},
    {"a Slack token", ~w(xoxb- xoxp- xoxa- xoxs- xoxe-), 20, :token},
    {"an OpenAI or Anthropic key", ~w(sk-), 32, :token},
    {"a Stripe key", ~w(sk_live_ rk_live_ sk_test_ rk_test_), 20, :token},
    {"an AWS access key", ~w(AKIA ASIA), 16, :upper},
    {"a Google API key", ~w(AIza), 35, :token},
    {"a Google access token", ~w(ya29.), 30, :dotted},
    {"an npm token", ~w(npm_), 36, :token},
    {"a PyPI token", ~w(pypi-), 50, :token},
    {"a Hugging Face token", ~w(hf_), 30, :token},
    {"a Tailscale key", ~w(tskey-), 20, :token},
    {"a DigitalOcean token", ~w(dop_v1_ doo_v1_ dor_v1_), 30, :token},
    {"a SendGrid key", ~w(SG.), 20, :dotted},
    {"a Shopify token", ~w(shpat_ shpca_ shppa_ shpss_), 20, :token},
    {"a Grafana token", ~w(glc_ glsa_), 20, :token},
    {"a Linear key", ~w(lin_api_), 20, :token},
    {"a Doppler token", ~w(dp.pt. dp.st.), 20, :dotted},
    {"a Postman key", ~w(PMAK-), 20, :token}
  ]

  @pem "-----BEGIN "
  @jwt "eyJ"
  @jwt_segment 10
  @most 20

  @by_prefix for {name, prefixes, least, chars} <- @shapes,
                 prefix <- prefixes,
                 into: %{},
                 do: {prefix, {name, least, chars}}

  @prefixes Map.keys(@by_prefix) ++ [@pem, @jwt]

  @doc "The shapes looked for: what each looks like, and the prefixes it starts with."
  @spec shapes() :: [{String.t(), [String.t()]}]
  def shapes do
    for({name, prefixes, _least, _chars} <- @shapes, do: {name, prefixes}) ++
      [{"a private key", [@pem <> "… PRIVATE KEY-----"]}, {"a JWT", [@jwt <> "….….…"]}]
  end

  @doc """
  Looks through `text` for real values (`secrets`, or nil for none) and
  credential shapes. A shape that is one of `ignore` (placeholders, which
  are MWT's own) is not one. At most #{@most} findings, one per line and
  thing, in the order they come.

      iex> alias MWTClient.Sandbox.Inbound
      iex> Inbound.check("all fine\\n", nil)
      :ok
      iex> Inbound.check("line one\\nkey=ghp_" <> String.duplicate("a", 36) <> "\\n", nil)
      {:found, [%{what: {:shape, "a GitHub token"}, line: 2}]}
  """
  @spec check(binary(), Secrets.t() | nil, [binary()]) :: :ok | {:found, [finding()]}
  def check(text, secrets, ignore \\ []) when is_binary(text) do
    values = for {at, _length, label} <- Secrets.matches(secrets, text), do: {at, value(label)}
    shapes = shaped(text, ignore)

    case Enum.sort_by(values ++ shapes, &elem(&1, 0)) do
      [] ->
        :ok

      found ->
        {:found,
         found
         |> lines(text)
         |> Enum.uniq()
         |> Enum.take(@most)}
    end
  end

  defp value({:value, name}), do: {:value, name}
  defp value({:placeholder, name}), do: {:value, name}

  @window 4 * 1024 * 1024
  # What a window keeps of the one before: longer than any form or shape
  # looked for, so one cut between two is still found whole.
  @overlap 64 * 1024

  @doc """
  `check/3` on the file at `path`, read a window at a time, each with the
  end of the one before: a file of any size is looked through whole, in
  little memory. Line numbers count from the file's start. `{:error,
  reason}` when it can't be read.
  """
  @spec check_file(Path.t(), Secrets.t() | nil, [binary()]) ::
          :ok | {:found, [finding()]} | {:error, File.posix()}
  def check_file(path, secrets, ignore \\ []) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          windows(io, "", 1, secrets, ignore, [])
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `line` is the line `carry`, the end of the window before, starts on.
  defp windows(io, carry, line, secrets, ignore, found) do
    case :file.read(io, @window) do
      {:ok, data} ->
        text = carry <> data

        here =
          case check(text, secrets, ignore) do
            :ok -> []
            {:found, findings} -> Enum.map(findings, &%{&1 | line: &1.line + line - 1})
          end

        keep = min(@overlap, byte_size(text))
        done = binary_part(text, 0, byte_size(text) - keep)
        line = line + length(:binary.matches(done, "\n"))
        carry = binary_part(text, byte_size(text) - keep, keep)
        found = (found ++ here) |> Enum.uniq() |> Enum.take(@most)
        windows(io, carry, line, secrets, ignore, found)

      :eof ->
        if found == [], do: :ok, else: {:found, found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  `text` with every real value of `secrets` written out as its grant's
  name, in every form.

      iex> alias MWTClient.Sandbox.{Inbound, Secrets}
      iex> secrets = Secrets.new([{{:value, "GitHub"}, Secrets.forms("ghp_0123456789abcdef")}])
      iex> Inbound.scrub(~s({"token":"ghp_0123456789abcdef"}), secrets)
      ~s({"token":"[GitHub's token]"})
  """
  @spec scrub(binary(), Secrets.t() | nil) :: binary()
  def scrub(text, secrets),
    do: Secrets.replace_each(secrets, text, fn {_kind, name} -> "[#{name}'s token]" end)

  @doc """
  A finding in words, for a card or the log.

      iex> MWTClient.Sandbox.Inbound.words(%{what: {:shape, "a JWT"}, line: 4})
      "something shaped like a JWT, line 4"
      iex> MWTClient.Sandbox.Inbound.words(%{what: {:value, "GitHub"}, line: 1})
      "GitHub's real value, line 1"
  """
  @spec words(finding()) :: String.t()
  def words(%{what: {:value, name}, line: line}), do: "#{name}'s real value, line #{line}"

  def words(%{what: {:shape, name}, line: line}),
    do: "something shaped like #{name}, line #{line}"

  @doc "Whether a finding is a real value, which always holds what it was found in."
  @spec value?(finding()) :: boolean()
  def value?(%{what: {:value, _}}), do: true
  def value?(_finding), do: false

  ## Shapes

  defp shaped(text, ignore) do
    pattern = :binary.compile_pattern(@prefixes)

    text
    |> :binary.matches(pattern)
    |> Enum.flat_map(fn {at, length} ->
      with true <- boundary?(text, at),
           {name, span} <- shape(text, at, binary_part(text, at, length)),
           false <- ignored?(text, at, span, ignore) do
        [{at, {:shape, name}}]
      else
        _ -> []
      end
    end)
  end

  # A prefix in the middle of a word ("risk-") starts nothing.
  defp boundary?(_text, 0), do: true
  defp boundary?(text, at), do: not word?(:binary.at(text, at - 1))

  defp shape(text, at, @pem) do
    rest = binary_part(text, at, min(byte_size(text) - at, 80))
    line = rest |> String.split("\n", parts: 2) |> hd()

    if Regex.match?(~r/PRIVATE KEY( BLOCK)?-----/, line),
      do: {"a private key", byte_size(line)}
  end

  defp shape(text, at, @jwt) do
    from = at + byte_size(@jwt)
    first = run(text, from, :token)
    after_first = from + first

    with true <- first + byte_size(@jwt) >= @jwt_segment,
         true <- dot?(text, after_first),
         second when second >= @jwt_segment <- run(text, after_first + 1, :token),
         true <- dot?(text, after_first + 1 + second),
         third when third >= @jwt_segment <- run(text, after_first + 2 + second, :token) do
      {"a JWT", after_first + 2 + second + third - at}
    else
      _ -> nil
    end
  end

  defp shape(text, at, prefix) do
    {name, least, chars} = Map.fetch!(@by_prefix, prefix)
    count = run(text, at + byte_size(prefix), chars)
    if count >= least, do: {name, byte_size(prefix) + count}
  end

  defp ignored?(text, at, span, ignore),
    do: Enum.any?(ignore, &(is_binary(&1) and &1 == binary_part(text, at, span)))

  defp dot?(text, at), do: at < byte_size(text) and :binary.at(text, at) == ?.

  # How many characters of the kind run from `at`, counted up to 4 KiB.
  defp run(text, at, chars) do
    stop = min(byte_size(text), at + 4096)
    count(text, at, stop, chars, 0)
  end

  defp count(_text, at, stop, _chars, n) when at >= stop, do: n

  defp count(text, at, stop, chars, n) do
    if char?(chars, :binary.at(text, at)),
      do: count(text, at + 1, stop, chars, n + 1),
      else: n
  end

  defp char?(:upper, c), do: c in ?A..?Z or c in ?0..?9
  defp char?(:token, c), do: word?(c) or c in [?_, ?-]
  defp char?(:dotted, c), do: char?(:token, c) or c == ?.

  defp word?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9

  ## Lines

  # Each position as its line, counted once through the text.
  defp lines(found, text) do
    breaks = for {at, _} <- :binary.matches(text, "\n"), do: at

    {findings, _breaks, _line} =
      Enum.reduce(found, {[], breaks, 1}, fn {at, what}, {acc, breaks, line} ->
        {before, rest} = Enum.split_while(breaks, &(&1 < at))
        line = line + length(before)
        {[%{what: what, line: line} | acc], rest, line}
      end)

    Enum.reverse(findings)
  end
end
