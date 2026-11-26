defmodule MWTClient.Storage.Retention do
  @moduledoc """
  What MWT keeps of each kind of thing, and for how long: one rule per
  kind, none shared between kinds. Each starts at its
  default; a rule changed is kept for the identity as the
  `storage.rules` document (`MWTClient.Storage.Documents`), and putting a
  kind back to its default forgets the change.

  A rule is made of the limits that make sense for its kind, any of which
  can be off (`nil`, or `false` for a switch):

    * `:days` - keep what is newer than this many days;
    * `:gb` - keep at most this many gigabytes, the oldest removed first;
    * `:count` - keep the newest this many;
    * `:every_days`, `:daily_days`, `:monthly`, `:most` - for versions:
      every version for `every_days`, then one a day until `daily_days`,
      then one a month (`monthly`) or none, and never more than `most` of
      one item.

  Notes, diagrams, cards and HTTP samples are never removed by any rule.
  `MWTClient.Storage.Janitor` applies the rules of what is in the
  databases and in the identity's folder; the sandbox applies the VM's
  when it takes a snapshot or builds an image.
  """

  alias MWTClient.Storage.Documents

  @document "storage.rules"

  @type field :: :days | :gb | :count | :every_days | :daily_days | :monthly | :most
  @type rule :: %{optional(field()) => pos_integer() | boolean() | nil}

  @typedoc """
  A kind: its `key`, what the page calls it, a line on what it holds, the
  limits its rule has, in order, its default rule, and, for some, what
  having every limit off means for it.
  """
  @type kind :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:about) => String.t(),
          required(:fields) => [field()],
          required(:default) => rule(),
          optional(:off) => String.t()
        }

  @versions [:every_days, :daily_days, :monthly, :most]
  @versions_default %{every_days: 90, daily_days: 365, monthly: true, most: 100}

  @kinds [
    %{
      key: "note_versions",
      label: "Note versions",
      about: "What a note held before each change kept, to restore.",
      fields: @versions,
      default: @versions_default
    },
    %{
      key: "diagram_versions",
      label: "Diagram versions",
      about: "What a diagram held before each change kept, to restore.",
      fields: @versions,
      default: @versions_default
    },
    %{
      key: "flashcard_versions",
      label: "Flash card versions",
      about: "What a card said before each change kept, to restore.",
      fields: @versions,
      default: @versions_default
    },
    %{
      key: "image_layer_versions",
      label: "Image layer versions",
      about: "What your layer of the VM's image held before each save, to restore.",
      fields: @versions,
      default: @versions_default
    },
    %{
      key: "http_history",
      label: "HTTP history",
      about: "Requests sent from the HTTP client, with their responses. Samples never sent stay.",
      fields: [:days, :gb],
      default: %{days: 90, gb: nil}
    },
    %{
      key: "http_bodies",
      label: "HTTP response bodies",
      about: "The bodies of those responses. Past this, an entry keeps its status and headers.",
      fields: [:days],
      default: %{days: nil},
      off: "as long as their entry"
    },
    %{
      key: "agent_activity",
      label: "Agent activity",
      about: "Every connection, lookup, ask, command, handoff and tool call of the VM's agents.",
      fields: [:days, :gb],
      default: %{days: 180, gb: 5}
    },
    %{
      key: "backups",
      label: "Backups",
      about: "Copies of both databases made by Back up now, each with its vault.json.",
      fields: [:count],
      default: %{count: 5}
    },
    %{
      key: "legacy",
      label: "Files from before",
      about: "The .bin files and versions/ folder kept before the databases, after their import.",
      fields: [:days],
      default: %{days: nil},
      off: "until you delete them"
    },
    %{
      key: "vm_snapshots",
      label: "VM Home snapshots",
      about: "Copies of the VM's Home disk, taken before it is recreated.",
      fields: [:count],
      default: %{count: 3}
    },
    %{
      key: "vm_images",
      label: "VM image builds",
      about: "Builds of the VM's image; the one the VM was made from stays too.",
      fields: [:count],
      default: %{count: 3}
    }
  ]

  # The most each limit takes, so a slip of the finger keeps nothing absurd.
  @most %{
    days: 36_500,
    gb: 10_000,
    count: 1_000,
    every_days: 36_500,
    daily_days: 36_500,
    most: 100_000
  }

  @doc "Every kind with a rule, in the order the Storage page lists them."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "One kind, by its key."
  @spec kind(String.t()) :: kind()
  def kind(key), do: Enum.find(@kinds, &(&1.key == key)) || raise(ArgumentError, "no kind #{key}")

  @doc "The rule `username` keeps `key` by: its default, with what was changed."
  @spec rule(String.t(), String.t()) :: rule()
  def rule(username, key), do: Map.merge(kind(key).default, Map.get(changed(username), key, %{}))

  @doc "Every kind's rule, by key."
  @spec rules(String.t()) :: %{String.t() => rule()}
  def rules(username) do
    changed = changed(username)
    Map.new(@kinds, &{&1.key, Map.merge(&1.default, Map.get(changed, &1.key, %{}))})
  end

  @doc "Whether `username` changed `key`'s rule from its default."
  @spec changed?(String.t(), String.t()) :: boolean()
  def changed?(username, key), do: rule(username, key) != kind(key).default

  @doc """
  Changes `key`'s rule with `attrs`, from a form (string keys and values)
  or code (atom keys). A limit left empty, `"off"` or `false` is off. Only
  the kind's own limits are read; a value that isn't a whole number from
  1 up comes back as an error, by field, and changes nothing.
  """
  @spec put(String.t(), String.t(), map()) :: {:ok, rule()} | {:error, [{field(), String.t()}]}
  def put(username, key, attrs) when is_map(attrs) do
    kind = kind(key)
    current = rule(username, key)

    {rule, errors} =
      Enum.reduce(kind.fields, {current, []}, fn field, {rule, errors} ->
        case fetch(attrs, field) do
          :error ->
            {rule, errors}

          {:ok, value} ->
            case value(field, value) do
              {:ok, value} -> {Map.put(rule, field, value), errors}
              {:error, message} -> {rule, [{field, message} | errors]}
            end
        end
      end)

    if errors == [] do
      :ok = keep(username, key, rule)
      {:ok, rule}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @doc "Puts `key`'s rule back to its default."
  @spec reset(String.t(), String.t()) :: :ok
  def reset(username, key) do
    _kind = kind(key)
    keep(username, key, nil)
  end

  @doc """
  A rule in a few words, for the page: `"90 days · at most 5 GB"`,
  `"every one for 90 days, then one a day for 365, then one a month"`.
  With every limit off, `off`: what that means for its kind.
  """
  @spec describe(rule(), String.t()) :: String.t()
  def describe(rule, off \\ "kept until you remove it")

  def describe(%{every_days: _} = rule, _off) do
    every =
      case rule.every_days do
        nil -> "every one"
        days -> "every one for #{days(days)}"
      end

    then =
      cond do
        rule.every_days == nil -> []
        rule.daily_days == nil -> ["then one a day"]
        rule.monthly -> ["then one a day until #{days(rule.daily_days)}", "then one a month"]
        true -> ["then one a day until #{days(rule.daily_days)}", "then none"]
      end

    most = if rule.most, do: ["at most #{rule.most} an item"], else: []
    Enum.join([every | then] ++ most, ", ")
  end

  def describe(rule, off) do
    parts =
      Enum.flat_map([:days, :count, :gb], fn
        :days -> if rule[:days], do: [days(rule.days)], else: []
        :count -> if rule[:count], do: ["the newest #{rule.count}"], else: []
        :gb -> if rule[:gb], do: ["at most #{rule.gb} GB"], else: []
      end)

    if parts == [], do: off, else: Enum.join(parts, " · ")
  end

  defp days(1), do: "1 day"
  defp days(days), do: "#{days} days"

  defp changed(username) do
    case Documents.get(username, @document) do
      {:ok, changed} when is_map(changed) -> changed
      _none -> %{}
    end
  end

  defp keep(username, key, rule) do
    kind = kind(key)
    changed = changed(username)

    changed =
      if rule == nil or rule == kind.default,
        do: Map.delete(changed, key),
        else: Map.put(changed, key, rule)

    Documents.put(username, @document, changed)
  end

  defp fetch(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(field))
    end
  end

  defp value(:monthly, value) when is_boolean(value), do: {:ok, value}
  defp value(:monthly, value) when value in ["true", "on"], do: {:ok, true}
  defp value(:monthly, value) when value in ["false", "off", ""], do: {:ok, false}
  defp value(:monthly, _value), do: {:error, "must be on or off"}

  defp value(_field, value) when value in [nil, false, "", "off"], do: {:ok, nil}

  defp value(field, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> value(field, number)
      _other -> {:error, "must be a whole number"}
    end
  end

  defp value(field, value) when is_integer(value) do
    most = Map.fetch!(@most, field)

    cond do
      value < 1 -> {:error, "must be 1 or more, or off"}
      value > most -> {:error, "must be at most #{most}"}
      true -> {:ok, value}
    end
  end

  defp value(_field, _value), do: {:error, "must be a whole number"}
end
