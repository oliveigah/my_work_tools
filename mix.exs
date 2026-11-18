# exqlite, the driver under Ecto's SQLite adapter, is built from source
# against SQLite3 Multiple Ciphers instead of its own SQLite, so MWT's
# databases are encrypted page by page (docs/storage.md). The flags must be
# set here, before any dependency compiles: exqlite reads them when its own
# mix.exs loads, and without them it downloads its stock, unencrypted NIF.
#
# scripts/build-sqlite3mc.sh downloads the pinned release, checks its
# SHA-256 and builds it into _build, once. A checkout without the script
# (the package build's stage that only fetches dependencies) sets the flags
# and builds nothing.
sqlite3mc = %{
  version: "2.7.1",
  sqlite: "3.54.1",
  sha256: "d6bc59678e015c5ac6d3ec5d7b657c351230b36c8052b185e446c9d52ba01af0"
}

sqlite3mc_dir = Path.expand("_build/sqlite3mc-#{sqlite3mc.version}", __DIR__)
sqlite3mc_script = Path.expand("scripts/build-sqlite3mc.sh", __DIR__)

if File.regular?(sqlite3mc_script) and
     not File.regular?(Path.join(sqlite3mc_dir, "libsqlite3mc.a")) do
  args = [sqlite3mc_script, sqlite3mc.version, sqlite3mc.sqlite, sqlite3mc.sha256, sqlite3mc_dir]

  erl = Path.join([:code.root_dir(), "bin", "erl"])

  case System.cmd("bash", args, into: IO.stream(), stderr_to_stdout: true, env: [{"ERL", erl}]) do
    {_output, 0} -> :ok
    {_output, status} -> Mix.raise("building SQLite3 Multiple Ciphers failed (exit #{status})")
  end
end

System.put_env(%{
  "EXQLITE_USE_SYSTEM" => "1",
  "EXQLITE_SYSTEM_CFLAGS" => "-I#{sqlite3mc_dir}/include",
  "EXQLITE_SYSTEM_LDFLAGS" => "#{sqlite3mc_dir}/libsqlite3mc.a -lm"
})

defmodule MWTClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :mwt_client,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # :native builds MWT's own Rust programs when their source changed
      # (Mix.Tasks.Compile.Native).
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:native],
      listeners: [Phoenix.CodeReloader],
      # Scripts kept from reviews (benches, probes), run one at a time when
      # asked, not part of the suite.
      test_ignore_filters: [&String.starts_with?(&1, "test/review/")]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {MWTClient.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:elixirkit, github: "livebook-dev/elixirkit"},
      {:req, "~> 0.7.4"},
      {:mdex, "~> 0.14.1"},
      {:ecto_sqlite3, "~> 0.26.0"},
      # Pinned apart: the top of this file relies on how it builds its NIF.
      {:exqlite, "~> 0.43.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind mwt_client", "esbuild mwt_client"],
      "assets.deploy": [
        "tailwind mwt_client --minify",
        "esbuild mwt_client --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
