# Checks the import of an identity's data into its databases, on a COPY of
# an MWT data folder.
#
#     mix run --no-start scripts/check-storage-import.exs DATA_FOLDER USERNAME
#
# It reads the identity's files from before the databases first, as an
# older build would, then unlocks it, which imports them the first time,
# and compares what the apps read with what the files held. The password
# is asked for and never echoed. The report holds counts, ids and field
# names, never content, so it can be pasted into a thread.

alias MWTClient.Accounts
alias MWTClient.Storage.{ImportCheck, Legacy}
alias MWTClient.Vault.Store

fail = fn message ->
  IO.puts(:stderr, message)
  System.halt(1)
end

{dir, username} =
  case System.argv() do
    [dir, username] -> {Path.expand(dir), username}
    _other -> fail.("Usage: mix run --no-start scripts/check-storage-import.exs DATA_FOLDER USERNAME")
  end

if dir == Path.join(System.user_home!(), ".mwt_client"),
  do: fail.("#{dir} is MWT's own data folder. Copy it, and check the copy.")

unless File.dir?(Path.join(dir, "identities")),
  do: fail.("#{dir} holds no identities/: give the folder that holds it.")

# Everything, the log included, goes to the copy.
Application.put_env(:mwt_client, :data_dir, dir)
{:ok, _apps} = Application.ensure_all_started(:mwt_client)

unless Accounts.exists?(username), do: fail.("No identity named #{inspect(username)} in #{dir}.")

IO.write("Password for #{username}: ")

# Not echoed from a terminal; read as a line when piped.
password =
  case :io.get_password() do
    {:error, _not_a_terminal} -> "" |> IO.gets() |> to_string() |> String.trim_trailing("\n")
    chars -> to_string(chars)
  end

IO.puts("")

case Accounts.sign_in(username, password) do
  {:ok, profile, key} ->
    user = profile.username
    before = ImportCheck.read_before(user, key)
    {microseconds, opened} = :timer.tc(fn -> Store.open(user, key) end)
    if opened != :ok, do: fail.("Unlocking failed: #{inspect(opened)}")

    user
    |> ImportCheck.compare(before)
    |> ImportCheck.lines(
      unlock_ms: div(microseconds, 1000),
      corrupt: ImportCheck.corrupt(user),
      not_imported: Legacy.failures(user)
    )
    |> Enum.each(&IO.puts/1)

    :ok = Store.close(user)

  {:error, reason} ->
    fail.("Signing in failed: #{reason}")
end
