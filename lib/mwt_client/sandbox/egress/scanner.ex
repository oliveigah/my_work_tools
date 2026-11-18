defmodule MWTClient.Sandbox.Egress.Scanner do
  @moduledoc """
  A stream of bytes looked through for `MWTClient.Sandbox.Secrets`, chunk
  by chunk, so a form split across two chunks is still found.

  Each chunk is looked at with the end of what went before it. Holding
  (`hold: true`), the bytes at the end of a chunk that could be the start
  of a form wait for the next one (`Secrets.partial/2`), so no part of a
  form is let through before MWT knows; the caller lets them go when the
  stream ends or pauses (`release/1`). Without holding, everything is let
  through at once and only looked at: for bytes going out of the VM, where
  holding back the end of a request would stall a client waiting for its
  answer.
  """

  alias MWTClient.Sandbox.Secrets

  @derive {Inspect, only: [:hold]}
  defstruct [:secrets, hold: false, seen: "", held: ""]

  @type t :: %__MODULE__{
          secrets: Secrets.t() | nil,
          hold: boolean(),
          seen: binary(),
          held: binary()
        }

  @doc "A scanner for `secrets` (nil looks for nothing); `hold: true` holds back possible starts."
  @spec new(Secrets.t() | nil, keyword()) :: t()
  def new(secrets, options \\ []),
    do: %__MODULE__{secrets: secrets, hold: Keyword.get(options, :hold, false)}

  @doc """
  The next chunk: `{:ok, bytes_to_let_through, scanner}`, or `{:found,
  label}` when a form is in it, counting what came before.
  """
  @spec feed(t(), binary()) :: {:ok, binary(), t()} | {:found, Secrets.label()}
  def feed(%__MODULE__{secrets: nil} = scanner, data), do: {:ok, data, scanner}

  def feed(%__MODULE__{secrets: secrets} = scanner, data) do
    pending = scanner.held <> data

    case Secrets.find(secrets, scanner.seen <> pending) do
      nil ->
        held = if scanner.hold, do: Secrets.partial(secrets, pending), else: 0
        out = binary_part(pending, 0, byte_size(pending) - held)

        {:ok, out,
         %{
           scanner
           | seen: following(scanner.seen, out, Secrets.longest(secrets) - 1),
             held: binary_part(pending, byte_size(pending) - held, held)
         }}

      label ->
        {:found, label}
    end
  end

  @doc """
  What is held back, let through: the stream ended or paused, so it isn't
  the start of a form after all, or what follows will be found with it.
  """
  @spec release(t()) :: {binary(), t()}
  def release(%__MODULE__{held: ""} = scanner), do: {"", scanner}

  def release(%__MODULE__{held: held} = scanner) do
    {held,
     %{
       scanner
       | seen: following(scanner.seen, held, Secrets.longest(scanner.secrets) - 1),
         held: ""
     }}
  end

  @doc "Whether bytes are held back."
  @spec held?(t()) :: boolean()
  def held?(%__MODULE__{held: held}), do: held != ""

  # The last `keep` bytes of `seen` followed by `out`, without copying a
  # whole chunk to find them.
  defp following(_seen, out, keep) when byte_size(out) >= keep,
    do: binary_part(out, byte_size(out) - keep, keep)

  defp following(seen, out, keep) do
    data = seen <> out
    binary_part(data, byte_size(data) - min(keep, byte_size(data)), min(keep, byte_size(data)))
  end
end
