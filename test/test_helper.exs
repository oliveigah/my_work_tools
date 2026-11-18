# Git also reads the machine's own config, which differs from one machine to
# the next: MWT's VM rewrites GitHub SSH URLs to HTTPS in /etc/gitconfig, and
# a developer's ~/.gitconfig may rewrite the other way or sign every commit.
# Tests see neither, so they behave the same everywhere. Every repository a
# test makes sets its own user.name and user.email.
System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})

# What tests put in place of each identity's VM and of Zed (config/test.exs).
MWTClient.StandIns.start()

# The CPU and KVM tests see (MWTClient.Sandbox.NestedVirt): one that allows
# VMs inside the VM, rather than whatever machine runs them.
nested_virt_root = Application.fetch_env!(:mwt_client, MWTClient.Sandbox.NestedVirt)[:root]
MWTClient.NestedVirtHelpers.fake_host!(nested_virt_root, :allowed)

# The benchmarks in test/bench take minutes; `mix test --only bench` runs them.
# The D-Bus tests start a private dbus-daemon, so they need one installed.
# The `:dpkg` tests build and read a Debian package, with dpkg-deb; the
# `:rpmbuild` ones a Fedora package, with rpmbuild (rpm-build on Fedora).
# The `:vm` tests boot a real VM: they need KVM, bwrap, MWT's runtime in
# priv/microsandbox (scripts/install-runtime.sh in the agent sandbox) and the
# internet; `mix test --only vm` runs them.
# The `:bwrap` tests run a command in the bubble a confined subgrant runs
# in (`MWTClient.Sandbox.Confine`), which needs bwrap and user namespaces.
exclude = if MWTClient.DBusDaemon.available?(), do: [:bench, :vm], else: [:bench, :vm, :dbus]
exclude = if MWTClient.Sandbox.Confine.available() == :ok, do: exclude, else: [:bwrap | exclude]
exclude = if System.find_executable("dpkg-deb"), do: exclude, else: [:dpkg | exclude]
exclude = if System.find_executable("rpmbuild"), do: exclude, else: [:rpmbuild | exclude]

# The `:present` tests run MWT's presentations, built from native/mwt_present
# by `mix compile` where Rust's musl target is installed.
exclude =
  if File.regular?(Path.expand("../priv/microsandbox/bin/mwt-present", __DIR__)),
    do: exclude,
    else: [:present | exclude]

# What the app logs while a test runs shows only when that test fails, under
# its failure: a run that passes prints its dots and its counts.
#
# A message a test waits for comes after a write to disk, a git command or a
# trip through D-Bus, which a full run's load makes take longer than
# assert_receive's 100 ms: it returns as soon as the message is there, so a
# second costs a test that passes nothing. refute_receive keeps its 100 ms.
ExUnit.start(exclude: exclude, capture_log: true, assert_receive_timeout: 1_000)

ExUnit.after_suite(fn _result ->
  File.rm_rf!(MWTClient.Accounts.root())
  # Each test identity has a folder of sockets of its own.
  File.rm_rf!(Application.get_env(:mwt_client, MWTClient.Sandbox.Server)[:channel_dir])
  File.rm_rf!(nested_virt_root)
end)
