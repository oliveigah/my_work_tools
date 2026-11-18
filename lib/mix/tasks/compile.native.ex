defmodule Mix.Tasks.Compile.Native do
  @shortdoc "Builds MWT's native programs when their source changed"

  @moduledoc """
  Builds MWT's own native programs, as part of `mix compile`, when their
  source is newer than what was built:

    * the relay, `native/mwt_relay`, the first process in the VM's bubble
      (`scripts/build-relay.sh`, into `priv/microsandbox/bin/mwt-relay`);
    * the ACP shell, `native/mwt_acp`, which runs in the VM for MWT's
      agents in Zed (`scripts/build-acp.sh`, into
      `priv/microsandbox/bin/mwt-acp`);
    * the presentations, `native/mwt_present`, which `mwt exec` runs in the
      VM when a token grant asks for one (`scripts/build-present.sh`, into
      `priv/microsandbox/bin/mwt-present`).

  Each is built through its script when its program is missing, or older
  than its script or any file of its crate (`Cargo.toml`, `Cargo.lock`,
  `src/`). Up to date, nothing runs. Neither has dependencies, so a build
  needs Rust and no network, a few seconds each.

  A checkout without the crates builds nothing: the package build copies no
  `native/` into the stages that compile, and builds the programs in a
  stage of its own. When a build can't run (no `cargo`, or the shell's
  musl target missing), it says what to do, and compiling goes on: the
  sandbox only needs them to run a VM. `MWT_NATIVE_BUILD=0` skips this step.

  The code reloader of the development server doesn't run it (its
  `:reloadable_compilers`), so a page never waits for Cargo.
  """

  use Mix.Task.Compiler

  @programs [
    {"native/mwt_relay", "scripts/build-relay.sh", "mwt-relay"},
    {"native/mwt_acp", "scripts/build-acp.sh", "mwt-acp"},
    {"native/mwt_present", "scripts/build-present.sh", "mwt-present"}
  ]

  @impl Mix.Task.Compiler
  def run(_args) do
    if System.get_env("MWT_NATIVE_BUILD") == "0" do
      {:noop, []}
    else
      root = Path.dirname(Mix.Project.project_file())
      out = Path.join(root, "priv/microsandbox")
      built = Enum.map(@programs, &build(root, out, &1))
      if :ok in built, do: {:ok, []}, else: {:noop, []}
    end
  end

  defp build(root, out, {crate, script, name}) do
    crate = Path.join(root, crate)
    script = Path.join(root, script)
    program = Path.join(out, "bin/#{name}")

    cond do
      not File.dir?(crate) or not File.regular?(script) ->
        :noop

      not stale?(program, [script | sources(crate)]) ->
        :noop

      System.find_executable("cargo") == nil ->
        can_not(name, "cargo isn't installed")

      true ->
        Mix.shell().info("==> #{name}: building it, its source changed")

        case System.cmd("bash", [script, out], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _status} -> can_not(name, output |> String.trim() |> last_lines(6))
        end
    end
  end

  @doc false
  # Whether `program` needs building: missing, or older than a source.
  @spec stale?(Path.t(), [Path.t()]) :: boolean()
  def stale?(program, sources) do
    case File.stat(program, time: :posix) do
      {:ok, %{mtime: built}} ->
        Enum.any?(sources, fn source ->
          match?({:ok, %{mtime: changed}} when changed > built, File.stat(source, time: :posix))
        end)

      {:error, _missing} ->
        true
    end
  end

  defp sources(crate) do
    [Path.join(crate, "Cargo.toml"), Path.join(crate, "Cargo.lock")] ++
      (Path.join(crate, "src/**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1))
  end

  defp can_not(name, why) do
    Mix.shell().error(
      "==> #{name} is out of date and wasn't built (the agent sandbox needs it to run a VM):\n" <>
        "#{why}\n(MWT_NATIVE_BUILD=0 skips this step.)"
    )

    :skipped
  end

  defp last_lines(text, count),
    do: text |> String.split("\n") |> Enum.take(-count) |> Enum.join("\n")
end
