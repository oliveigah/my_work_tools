defmodule MWTClient.Sandbox.Secrets do
  @moduledoc """
  What MWT looks for in bytes passing through it: real values, and
  placeholders where they don't belong, each under a label that says whose
  it is (`{:value, grant_name}`, `{:placeholder, grant_name}`).

  Every form of every entry goes into one pattern, compiled once
  (`:binary.compile_pattern/1`): Boyer-Moore for one form, Aho-Corasick
  for several, in C. About 8 GiB/s a core for one form and 950 MiB/s for
  many, measured on 64 KiB chunks: less than the TLS that intercepted
  bytes already go through, so looking costs no extra copy and no NIF.

  A value is looked for as it is and in the forms it takes when a service
  quotes it (`forms/1`): JSON-escaped and percent-encoded, where those
  differ. Forms shorter than 16 bytes are left out: too many ordinary
  strings would match.

  The struct holds real values. It never prints them: `inspect/1` shows
  only how many forms it holds, so a crash report can't carry one.
  """

  @derive {Inspect, only: [:count]}
  @enforce_keys [:pattern, :labels, :forms, :firsts, :longest, :count]
  defstruct [:pattern, :labels, :forms, :firsts, :longest, :count]

  @type label :: {:value, String.t()} | {:placeholder, String.t()}

  @opaque t :: %__MODULE__{
            pattern: :binary.cp(),
            labels: %{binary() => label()},
            forms: [binary()],
            firsts: :binary.cp(),
            longest: pos_integer(),
            count: pos_integer()
          }

  @shortest 16

  @doc "The shortest form looked for, in bytes."
  @spec shortest() :: pos_integer()
  def shortest, do: @shortest

  @doc """
  The forms of `entries`, each `{label, forms}`, as one pattern; nil when
  none is at least `shortest` bytes long (16 unless said). Where two
  entries share a form, the first one's label is kept.
  """
  @spec new([{label(), [binary()]}], pos_integer()) :: t() | nil
  def new(entries, shortest \\ @shortest) do
    labels =
      Enum.reduce(entries, %{}, fn {label, forms}, acc ->
        Enum.reduce(forms, acc, fn form, acc ->
          if is_binary(form) and byte_size(form) >= shortest,
            do: Map.put_new(acc, form, label),
            else: acc
        end)
      end)

    case Map.keys(labels) do
      [] ->
        nil

      forms ->
        firsts = forms |> Enum.map(&binary_part(&1, 0, 1)) |> Enum.uniq()

        %__MODULE__{
          pattern: :binary.compile_pattern(forms),
          labels: labels,
          forms: forms,
          firsts: :binary.compile_pattern(firsts),
          longest: forms |> Enum.map(&byte_size/1) |> Enum.max(),
          count: length(forms)
        }
    end
  end

  @doc """
  A value as it is, and as a service quoting it would write it: JSON-escaped
  (with and without `\\/`) and percent-encoded, where those differ.

      iex> MWTClient.Sandbox.Secrets.forms("abc/def+ghi")
      ["abc/def+ghi", "abc\\\\/def+ghi", "abc%2Fdef%2Bghi"]
  """
  @spec forms(String.t()) :: [String.t()]
  def forms(value) do
    json = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

    Enum.uniq([
      value,
      json,
      String.replace(json, "/", "\\/"),
      URI.encode(value, &URI.char_unreserved?/1),
      URI.encode_www_form(value)
    ])
  end

  @doc """
  The label of the first form found in `data`, or nil.

      iex> secrets = MWTClient.Sandbox.Secrets.new([{{:value, "GitHub"}, ["ghp_0123456789abcdef"]}])
      iex> MWTClient.Sandbox.Secrets.find(secrets, "seen=token ghp_0123456789abcdef")
      {:value, "GitHub"}
      iex> MWTClient.Sandbox.Secrets.find(secrets, "seen=token ghp_0123")
      nil
  """
  @spec find(t() | nil, binary()) :: label() | nil
  def find(nil, _data), do: nil

  def find(%__MODULE__{pattern: pattern, labels: labels}, data) do
    case :binary.match(data, pattern) do
      {at, length} -> Map.fetch!(labels, binary_part(data, at, length))
      :nomatch -> nil
    end
  end

  @doc """
  `data` with every form found replaced by `replacement`.

      iex> secrets = MWTClient.Sandbox.Secrets.new([{{:value, "GitHub"}, ["ghp_0123456789abcdef"]}])
      iex> MWTClient.Sandbox.Secrets.replace(secrets, "x-echo: token ghp_0123456789abcdef", "ghp_mwt")
      "x-echo: token ghp_mwt"
  """
  @spec replace(t() | nil, binary(), binary()) :: binary()
  def replace(nil, data, _replacement), do: data

  def replace(%__MODULE__{pattern: pattern}, data, replacement),
    do: :binary.replace(data, pattern, replacement, [:global])

  @doc """
  Every form found in `data`, as `{position, length, label}`, in order.

      iex> secrets = MWTClient.Sandbox.Secrets.new([{{:value, "GitHub"}, ["ghp_0123456789abcdef"]}])
      iex> MWTClient.Sandbox.Secrets.matches(secrets, "a ghp_0123456789abcdef")
      [{2, 20, {:value, "GitHub"}}]
  """
  @spec matches(t() | nil, binary()) :: [{non_neg_integer(), pos_integer(), label()}]
  def matches(nil, _data), do: []

  def matches(%__MODULE__{pattern: pattern, labels: labels}, data) do
    for {at, length} <- :binary.matches(data, pattern),
        do: {at, length, Map.fetch!(labels, binary_part(data, at, length))}
  end

  @doc """
  `data` with every form found replaced by what `replacement` gives for its
  label.

      iex> secrets = MWTClient.Sandbox.Secrets.new([{{:value, "GitHub"}, ["ghp_0123456789abcdef"]}])
      iex> MWTClient.Sandbox.Secrets.replace_each(secrets, "x ghp_0123456789abcdef y", fn {_, name} -> name end)
      "x GitHub y"
  """
  @spec replace_each(t() | nil, binary(), (label() -> binary())) :: binary()
  def replace_each(nil, data, _replacement), do: data

  def replace_each(%__MODULE__{} = secrets, data, replacement) do
    {parts, last} =
      Enum.reduce(matches(secrets, data), {[], 0}, fn {at, length, label}, {parts, from} ->
        {[replacement.(label), binary_part(data, from, at - from) | parts], at + length}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(data, last, byte_size(data) - last) | parts]))
  end

  @doc """
  How many bytes at the end of `data` could be the start of a form: the
  longest such end, shorter than the form. Those are what a stream holds
  back until it knows.

      iex> secrets = MWTClient.Sandbox.Secrets.new([{{:value, "GitHub"}, ["ghp_0123456789abcdef"]}])
      iex> MWTClient.Sandbox.Secrets.partial(secrets, ~s({"seen":"ghp_01))
      6
      iex> MWTClient.Sandbox.Secrets.partial(secrets, ~s({"seen":"x"}))
      0
  """
  @spec partial(t() | nil, binary()) :: non_neg_integer()
  def partial(nil, _data), do: 0

  def partial(%__MODULE__{} = secrets, data) do
    size = byte_size(data)
    from = max(size - (secrets.longest - 1), 0)
    tail = binary_part(data, from, size - from)

    # Positions are found in order, so the first that fits is the longest end.
    tail
    |> :binary.matches(secrets.firsts)
    |> Enum.find_value(0, fn {at, _} ->
      ending = binary_part(tail, at, byte_size(tail) - at)

      if Enum.any?(
           secrets.forms,
           &(byte_size(&1) > byte_size(ending) and String.starts_with?(&1, ending))
         ),
         do: byte_size(ending)
    end)
  end

  @doc "The longest form, in bytes: how much of what went before a match can still need."
  @spec longest(t() | nil) :: non_neg_integer()
  def longest(nil), do: 0
  def longest(%__MODULE__{longest: longest}), do: longest
end
