defmodule MWTClient.Transfer.Archive do
  @moduledoc """
  The export file format.

      <<"MWTEXPORT", version::8, header_size::32, header::binary, payload::binary>>

  The header is JSON holding what is needed to derive the key again from a
  password — the KDF parameters and a salt, as in `vault.json` — plus a
  verifier: a constant sealed under that key, which tells a wrong key apart
  from a damaged file. The payload is the contents, compressed and sealed
  with `MWTClient.Vault`.

  Nothing here holds a key. Sealing goes through a function, so an export can
  be sealed by `MWTClient.Vault.Keyring` under the identity's own key; opening
  takes either that same kind of function or the password, whose key is
  derived again from the header.

  An export made when MWT was MDT imports too: it starts `MDTEXPORT`, seals
  `mdt:export:verifier:v1`, and names MDT's modules (`MDTClient.…`), read
  as MWT's. This is the one place that reads anything of MDT's.
  """

  alias MWTClient.Vault

  @magic "MWTEXPORT"
  @version 1
  @verifier "mwt:export:verifier:v1"
  @mdt_magic "MDTEXPORT"
  @mdt_verifier "mdt:export:verifier:v1"
  @algorithm "pbkdf2-hmac-sha512"
  @key_bytes 32
  # The header is read before anything is authenticated, so a file could ask
  # for enough iterations to hang the app. This is ~15x the current setting.
  @max_iterations 10_000_000

  @typedoc "Seals a term under some key, as `MWTClient.Vault.seal/2` does."
  @type seal :: (term() -> binary())

  @typedoc """
  How to open an export: with the password it was sealed under, or with a
  function that opens blobs sealed under a key already at hand.
  """
  @type opener :: {:password, String.t()} | {:open, (binary() -> {:ok, term()} | :error)}

  @type error :: :not_an_export | :unsupported_version | :bad_password | :damaged

  @doc """
  Seals `contents` with `seal`.

  `kdf` goes into the header as is, and must say how the sealing key derives
  from its password: `"algorithm"`, `"iterations"`, `"length"` and a base64
  `"salt"`, as `MWTClient.Vault.Keyring.kdf/1` returns them.
  """
  @spec encode(term(), map(), seal()) :: binary()
  def encode(contents, %{"salt" => _salt} = kdf, seal) when is_function(seal, 1) do
    header = Jason.encode!(%{"kdf" => kdf, "verifier" => Base.encode64(seal.(@verifier))})

    # Compressed before sealing, since ciphertext does not compress. Response
    # bodies are mostly text, so this is where most of an export's size goes.
    payload = seal.(:erlang.term_to_binary(contents, compressed: 6))

    <<@magic, @version, byte_size(header)::32, header::binary, payload::binary>>
  end

  @doc """
  Opens an export.

  Only a holder of the key could have produced a payload that authenticates,
  and the payload is decoded only once it has.
  """
  @spec decode(binary(), opener()) :: {:ok, term()} | {:error, error()}
  def decode(<<@magic, @version, size::32, header::binary-size(size), payload::binary>>, opener),
    do: decode(header, payload, opener, @verifier, & &1)

  def decode(
        <<@mdt_magic, @version, size::32, header::binary-size(size), payload::binary>>,
        opener
      ),
      do: decode(header, payload, opener, @mdt_verifier, &from_mdt/1)

  # This version's magic, cut short inside its header: damaged, not newer.
  def decode(<<magic::binary-size(9), @version, _rest::binary>>, _opener)
      when magic in [@magic, @mdt_magic],
      do: {:error, :damaged}

  def decode(<<magic::binary-size(9), _newer, _rest::binary>>, _opener)
      when magic in [@magic, @mdt_magic],
      do: {:error, :unsupported_version}

  def decode(_binary, _opener), do: {:error, :not_an_export}

  defp decode(header, payload, opener, expected, read) do
    with {:ok, salt, params, verifier} <- parse_header(header),
         open = opener(opener, salt, params),
         {:verifier, {:ok, ^expected}} <- {:verifier, open.(verifier)},
         {:ok, compressed} <- open.(payload),
         {:ok, contents} <- decompress(compressed) do
      {:ok, read.(contents)}
    else
      {:verifier, _mismatch} -> {:error, :bad_password}
      _damaged -> {:error, :damaged}
    end
  end

  # What MDT exported, with its modules' names (`Elixir.MDTClient…`) and its
  # own atom (`:mdt`) read as MWT's. Atoms are made only from a payload that
  # authenticated: as many as it held already.
  defp from_mdt(term) when is_atom(term) do
    case Atom.to_string(term) do
      "mdt" -> :mwt
      "Elixir.MDTClient" <> rest -> String.to_atom("Elixir.MWTClient" <> rest)
      _ -> term
    end
  end

  defp from_mdt([head | tail]), do: [from_mdt(head) | from_mdt(tail)]

  defp from_mdt(map) when is_map(map),
    do: map |> :maps.to_list() |> Map.new(fn {key, value} -> {from_mdt(key), from_mdt(value)} end)

  defp from_mdt(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&from_mdt/1) |> List.to_tuple()

  defp from_mdt(other), do: other

  defp opener({:password, password}, salt, params) when is_binary(password) do
    key = Vault.derive(password, salt, params)
    &Vault.open(key, &1)
  end

  defp opener({:open, open}, _salt, _params) when is_function(open, 1), do: open

  defp parse_header(header) do
    with {:ok, %{"kdf" => kdf, "verifier" => verifier}} <- Jason.decode(header),
         %{"algorithm" => @algorithm, "length" => @key_bytes, "iterations" => iterations} <- kdf,
         true <- is_integer(iterations) and iterations in 1..@max_iterations,
         {:ok, salt} <- decode64(kdf["salt"]),
         {:ok, verifier} <- decode64(verifier) do
      {:ok, salt, kdf, verifier}
    else
      _invalid -> :error
    end
  end

  defp decode64(value) when is_binary(value), do: Base.decode64(value)
  defp decode64(_value), do: :error

  # Plain `binary_to_term/1` for the reason given in `MWTClient.Vault.open/2`.
  # Unlike a vault file an export can come from elsewhere, but only from
  # someone who held its key; `docs/transfer.md` covers what that trusts.
  defp decompress(compressed) when is_binary(compressed) do
    {:ok, :erlang.binary_to_term(compressed)}
  rescue
    ArgumentError -> :error
  end

  defp decompress(_other), do: :error
end
