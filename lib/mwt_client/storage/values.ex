defmodule MWTClient.Storage.Values do
  @moduledoc """
  How values MWT keeps are written into its databases' columns, and read
  back.

    * **Times** are microseconds since 1970, UTC, an `INTEGER`, so they
      sort and compare in SQL. They come back as `DateTime`s to the
      microsecond, whatever precision they went in with: an app hands
      back what it wrote as `time/1` after `from_time/1` (`stored_time/1`),
      so what a write returns is what a later read returns.
    * **Terms**, such as a diagram's elements, a version's content or a
      whole HTTP response, are `term_to_binary` compressed with zstd at
      level 3, in a `BLOB`: a 1 MB response takes about 2 ms, where zlib
      took 8 to 20, and comes out as small. They are read back with plain
      `binary_to_term`: the databases are encrypted and authenticated
      page by page, so no page can be made or changed without the key,
      as with `MWTClient.Vault.open/2`. What the tag can't tell is an old
      copy of a page put back by someone who can write the files; a term
      over several pages could then mix two of MWT's own writes, never
      bytes of someone else's (docs/storage.md, "Not covered").
  """

  @doc "A time as a column holds it: microseconds since 1970, or nil."
  @spec time(DateTime.t() | nil) :: integer() | nil
  def time(nil), do: nil
  def time(%DateTime{} = time), do: DateTime.to_unix(time, :microsecond)

  @doc "A time read from a column."
  @spec from_time(integer() | nil) :: DateTime.t() | nil
  def from_time(nil), do: nil

  def from_time(microseconds) when is_integer(microseconds),
    do: DateTime.from_unix!(microseconds, :microsecond)

  @doc "A time as it comes back once kept: the same instant, to the microsecond, in UTC."
  @spec stored_time(DateTime.t() | nil) :: DateTime.t() | nil
  def stored_time(time), do: time |> time() |> from_time()

  @doc "A term as a column holds it: a compressed blob, bound as one."
  @spec term(term()) :: {:blob, binary()}
  def term(term) do
    compressed = :zstd.compress(:erlang.term_to_binary(term), %{compressionLevel: 3})
    {:blob, IO.iodata_to_binary(compressed)}
  end

  @doc "A term read from a column; one MDT wrote is read as MWT's (`MWTClient.FormerName`)."
  @spec from_term(binary()) :: term()
  def from_term(blob) when is_binary(blob),
    do:
      blob
      |> :zstd.decompress()
      |> IO.iodata_to_binary()
      |> MWTClient.FormerName.binary_to_term()

  @doc "Strings as a column holds them: a JSON array."
  @spec strings([String.t()]) :: String.t()
  def strings(strings) when is_list(strings), do: Jason.encode!(strings)

  @doc "Strings read from a column."
  @spec from_strings(String.t()) :: [String.t()]
  def from_strings(json) when is_binary(json), do: Jason.decode!(json)
end
