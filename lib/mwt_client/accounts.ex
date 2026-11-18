defmodule MWTClient.Accounts do
  @moduledoc """
  Local user profiles, each owning an encrypted directory.

  A profile is a `{username, password}` pair. Signing in with an unknown
  username creates one; signing in with a known one derives its key from the
  stored salt and proves the password by opening the verifier.

  Nothing secret is written in the clear: `vault.json` holds a salt, the KDF
  parameters, a sealed constant, and the identity's data key sealed with the
  password's key, all useless without the password.

  The data key is random. It, not the password's key, is what the
  identity's databases are encrypted under (`MWTClient.Storage`), so a new
  password only needs the data key sealed again. An identity made before
  there was one gets it at its first unlock (`data_key/2`).
  """

  alias MWTClient.Vault

  @verifier "mwt:vault:verifier:v1"
  @version 1
  @data_key_bytes 32
  # How SQLite3 Multiple Ciphers opens the identity's databases. The data
  # key is random, so its own key stretching would add only time (25 to 30
  # ms per connection at its default). Kept in vault.json because a file
  # opens only with the settings it was made with.
  @storage %{"cipher" => "chacha20", "kdf_iter" => 1}

  @type profile :: %{username: String.t(), initials: String.t()}

  @doc "The directory holding preferences and every identity."
  @spec root() :: Path.t()
  def root do
    Application.get_env(
      :mwt_client,
      :data_dir,
      Path.join(System.user_home!(), ".mwt_client")
    )
  end

  @doc "Usernames are matched case insensitively and without surrounding space."
  @spec normalize(String.t()) :: String.t()
  def normalize(username), do: username |> String.trim() |> String.downcase()

  @doc """
  The directory name for a username.

  Hashed so that a directory listing cannot enumerate who uses the machine,
  and so any username is a safe path segment.
  """
  @spec id(String.t()) :: String.t()
  def id(username) do
    :sha256 |> :crypto.hash(normalize(username)) |> Base.encode16(case: :lower)
  end

  @doc "The directory owning one identity's encrypted files."
  @spec dir(String.t()) :: Path.t()
  def dir(username), do: Path.join([root(), "identities", id(username)])

  @doc "The path of one of an identity's encrypted stores."
  @spec store_path(String.t(), String.t()) :: Path.t()
  def store_path(username, name), do: Path.join(dir(username), name)

  @doc "Whether a profile already exists for this username."
  @spec exists?(String.t()) :: boolean()
  def exists?(username) do
    username |> vault_path() |> File.exists?()
  end

  @doc """
  Unlocks an existing profile, or creates one when the username is new.

  Returns the derived key, which the caller hands to `MWTClient.Vault.Store`
  and otherwise keeps out of sight.
  """
  @spec sign_in(String.t(), String.t()) ::
          {:ok, profile(), Vault.key()}
          | {:error, :bad_password | :blank_username | :blank_password | :unreadable_vault}
  def sign_in(username, password) do
    cond do
      normalize(username) == "" -> {:error, :blank_username}
      password in [nil, ""] -> {:error, :blank_password}
      exists?(username) -> unlock(username, password)
      true -> create(username, password)
    end
  end

  @doc """
  How an identity's key is derived from its password: the KDF parameters and
  the base64 salt, as stored in `vault.json`. None of it is secret.
  """
  @spec kdf(String.t()) :: {:ok, map()} | {:error, :unreadable_vault}
  def kdf(username) do
    with {:ok, meta} <- read_vault(username), do: {:ok, meta["kdf"]}
  end

  @doc """
  The identity's data key, opened with its password's `key`, and the cipher
  settings of its databases.

  An identity without a data key, made before there was one, gets one now,
  written into `vault.json` beside what is there; the `vault.json` it had
  is kept first, as `legacy/vault.json`, the way back to a build from
  before. Two unlocks at once agree on one key: the second finds the
  first's. Never beside databases already there: they were made with a key
  this `vault.json` lost, and a new one would replace them with empty ones
  (`:data_key_missing`).
  """
  @spec data_key(String.t(), Vault.key()) ::
          {:ok, binary(), map()} | {:error, :unreadable_vault | :data_key_missing}
  def data_key(username, key) do
    :global.trans({{__MODULE__, :data_key, id(username)}, self()}, fn ->
      with {:ok, meta} <- read_vault(username) do
        case meta do
          # A key there is never replaced, whatever else is missing: the
          # databases open with it alone.
          %{"data_key" => sealed} ->
            with {:ok, blob} <- decode(sealed),
                 {:ok, data_key} when byte_size(data_key) == @data_key_bytes <-
                   Vault.open(key, blob) do
              {:ok, data_key, Map.get(meta, "storage", @storage)}
            else
              _unreadable -> {:error, :unreadable_vault}
            end

          %{} ->
            with :ok <- key_kept(meta, username),
                 :ok <- keep_before(username) do
              data_key = :crypto.strong_rand_bytes(@data_key_bytes)
              meta = Map.merge(meta, sealed_data_key(key, data_key))

              case write_vault(username, meta) do
                :ok -> {:ok, data_key, @storage}
                {:error, _reason} -> {:error, :unreadable_vault}
              end
            end
        end
      end
    end)
  end

  @doc "The profile shown in the app chrome."
  @spec profile(String.t()) :: profile()
  def profile(username) do
    username = normalize(username)
    %{username: username, initials: initials(username)}
  end

  defp create(username, password) do
    salt = Vault.salt()
    key = Vault.derive(password, salt)

    meta =
      Map.merge(
        %{
          "version" => @version,
          "username" => normalize(username),
          "kdf" => Map.put(Vault.kdf_params(), "salt", Base.encode64(salt)),
          "verifier" => Base.encode64(Vault.seal(key, @verifier)),
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        sealed_data_key(key, :crypto.strong_rand_bytes(@data_key_bytes))
      )

    :ok = write_vault(username, meta)

    {:ok, profile(username), key}
  end

  defp sealed_data_key(key, data_key) do
    %{"data_key" => Base.encode64(Vault.seal(key, data_key)), "storage" => @storage}
  end

  # The vault.json from before the data key, beside the files from before
  # (`MWTClient.Storage.Legacy`): with them, a build from before opens the
  # identity as it was.
  defp keep_before(username) do
    legacy = store_path(username, "legacy")

    with :ok <- File.mkdir_p(legacy),
         {:ok, _bytes} <- File.copy(vault_path(username), Path.join(legacy, "vault.json")) do
      :ok
    else
      {:error, _reason} -> {:error, :unreadable_vault}
    end
  end

  # Written aside and renamed into place: a vault.json cut short would lock
  # its identity out for good.
  defp write_vault(username, meta) do
    path = vault_path(username)
    partial = path <> ".part"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(partial, Jason.encode!(meta, pretty: true), [:sync]) do
      File.rename(partial, path)
    end
  end

  defp unlock(username, password) do
    with {:ok, meta} <- read_vault(username),
         {:ok, salt} <- decode(meta["kdf"]["salt"]),
         {:ok, verifier} <- decode(meta["verifier"]),
         key = Vault.derive(password, salt, meta["kdf"]),
         {:ok, @verifier} <- Vault.open(key, verifier),
         :ok <- key_kept(meta, username) do
      {:ok, profile(username), key}
    else
      {:error, :unreadable_vault} -> {:error, :unreadable_vault}
      {:error, :data_key_missing} -> {:error, :data_key_missing}
      :error -> {:error, :bad_password}
      _mismatch -> {:error, :bad_password}
    end
  end

  # Databases there without a data key in vault.json were made with one this
  # vault.json lost (an older copy put back): a new key would make empty
  # databases in their place and leave theirs unreadable for good.
  defp key_kept(meta, username) do
    if Map.has_key?(meta, "data_key") or not databases?(username),
      do: :ok,
      else: {:error, :data_key_missing}
  end

  defp databases?(username),
    do: Enum.any?(~w(library.db journal.db), &File.exists?(store_path(username, &1)))

  defp vault_path(username), do: Path.join(dir(username), "vault.json")

  defp read_vault(username) do
    with {:ok, body} <- File.read(vault_path(username)),
         {:ok, %{"kdf" => %{"salt" => _}, "verifier" => _} = meta} <- Jason.decode(body) do
      {:ok, meta}
    else
      _unreadable -> {:error, :unreadable_vault}
    end
  end

  defp decode(value) when is_binary(value), do: Base.decode64(value)
  defp decode(_value), do: :error

  defp initials(username) do
    username
    |> String.split(~r/[._\-\s@]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end
end
