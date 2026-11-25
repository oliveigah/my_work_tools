import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mwt_client, MWTClientWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "es3iXg62cZ/nhOeFiFoKUtbMcjvDfNcQFanIwcNKukmDNW0YShvqkHTEQAYQ68JZ",
  server: false

config :mwt_client,
  data_dir: Path.join(System.tmp_dir!(), "mwt_client_test_data_#{System.pid()}"),
  log_dir: Path.join(System.tmp_dir!(), "mwt_client_test_logs_#{System.pid()}"),
  # Tests add remotes that do not exist; the ones about fetching turn it on.
  git_auto_fetch: false

# The sandbox never calls msb in tests, and its sockets sit in a folder of
# their own, one per run: test_helper.exs removes it when the run ends, and
# a run in another worktree must not lose its sockets then.
config :mwt_client, MWTClient.Sandbox.Server,
  external: false,
  channel_dir: Path.join(System.tmp_dir!(), "mwt-test-channels-#{System.pid()}")

# What tests take for this machine's CPU and KVM: one that allows VMs inside
# the VM, written by test_helper.exs, the same wherever they run.
config :mwt_client, MWTClient.Sandbox.NestedVirt,
  root: Path.join(System.tmp_dir!(), "mwt_client_test_cpu_#{System.pid()}")

# A runtime built into priv/microsandbox stays out of tests; the ones about
# msb make their own. So does your ~/.ssh/config.
config :mwt_client, MWTClient.Sandbox.Msb,
  runtime_dir: Path.join(System.tmp_dir!(), "mwt_client_test_msb_#{System.pid()}"),
  ssh_config: Path.join(System.tmp_dir!(), "mwt_client_test_no_ssh_config")

# What stands in for an identity's VM and for Zed, which each test puts in
# place for the identity it signed in as (MWTClient.StandIns, in
# test/support): tests that each have their own run at the same time. With
# none, the VM isn't running, and Zed never opens.
config :mwt_client, MWTClient.Sandbox.Projects, guest: &MWTClient.StandIns.guest/1
config :mwt_client, MWTClient.Sandbox.Zed, open: &MWTClient.StandIns.open_zed/2

# The workspace goes in a home folder of each identity's own, under the
# test data folder, never yours; opening it opens nothing.
config :mwt_client, MWTClient.Sandbox.Workspace,
  home: &MWTClient.StandIns.workspace_home/1,
  open: &MWTClient.StandIns.open_folder/1

# A new identity's password is stretched 600,000 times, about 150ms by
# design; the suite makes over a thousand of them, so it builds with fewer.
# An identity keeps the count it was made with, so unlocking still reads it
# from vault.json, as it does for a real one.
config :mwt_client, MWTClient.Vault, iterations: 1_000

# A database write that returns has reached the disk, which takes a few
# milliseconds a write; the suite opens two databases for each of over a
# thousand identities, and keeps none of them, so it doesn't wait for that.
config :mwt_client, MWTClient.Storage.Database, synchronous: :off

# Retention runs only when a test asks it to: on its own, an hour's sweep
# could remove what a test made with old dates.
config :mwt_client, MWTClient.Storage.Janitor, every_ms: nil

# Tests never show desktop notifications; the service only keeps track of
# what it would show. The D-Bus tests start their own bus.
config :mwt_client, MWTClient.Notifications.Center, address: nil

# Host commands, minted values and the tool probe run `bash -lc`, which reads
# the login profile of whoever runs the tests and prints whatever it prints.
# A home that doesn't exist keeps it out; /etc/profile still runs.
config :mwt_client, MWTClient.Sandbox.HostRun,
  home: Path.join(System.tmp_dir!(), "mwt_client_test_home_#{System.pid()}")

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Request subgrants send through Req: in tests a stub answers instead of the
# service (`Req.Test.stub(MWTClient.Sandbox.SavedRequest, ...)`).
config :mwt_client, MWTClient.Sandbox.SavedRequest,
  plug: {Req.Test, MWTClient.Sandbox.SavedRequest}

# A fixed call goes through MWT's proxy: its upstream, in tests, is a
# server on the loopback that answers with that stub
# (`MWTClient.FixedCallUpstream`).
config :mwt_client, MWTClient.Sandbox.Egress.FixedCall,
  upstream: {MWTClient.FixedCallUpstream, :upstream}

# A GitHub App's installation token is traded for at GitHub: in tests a stub
# answers (`Req.Test.stub(MWTClient.Sandbox.Adapter.GitHub, ...)`).
config :mwt_client, MWTClient.Sandbox.Adapter.GitHub,
  plug: {Req.Test, MWTClient.Sandbox.Adapter.GitHub}

config :mwt_client, MWTClient.Sandbox.Adapter.Google,
  plug: {Req.Test, MWTClient.Sandbox.Adapter.Google}
