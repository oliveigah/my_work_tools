defmodule MWTClient.Storage.LibraryRepo do
  @moduledoc """
  The Ecto repo of every identity's `library.db`: what you make.

  It is only ever started as a dynamic repo, one per unlocked identity
  (`MWTClient.Storage.Database`); use it through `MWTClient.Storage.run/3`.
  """

  use Ecto.Repo, otp_app: :mwt_client, adapter: Ecto.Adapters.SQLite3
end
