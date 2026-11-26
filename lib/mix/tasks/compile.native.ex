defmodule Mix.Tasks.Compile.Native do
  @shortdoc "Builds MWT's native programs when their source changed"

  @moduledoc """
  Builds MWT's own native programs, as part of `mix compile`, when their
  source is newer than what was built:

    * the relay, `native/mwt_relay`, the first process in the VM's bubble
      (`scripts/build-relay.sh`, into `priv/microsandbox/bin/mwt-relay`);
    * the presentations, `native/mwt_present`, which `mwt exec` runs in the
      VM when a token grant asks for one (`scripts/build-present.sh`, into
      `priv/microsandbox/bin/mwt-present`).

  Each is built through its script when its program is missing, or older
  than its script or any file of its crate (`Cargo.toml`, `Cargo.lock`,
  `src/`). Up to date, nothing runs. Neither has dependencies, so a build
  needs Rust and no network, a few seconds each.

  A checkout without the crates builds nothing: the package build copies no
  `native/` into the stages that compile, and builds the programs in a
  stage of its own. When a build can't run (no `cargo`, or the musl target
  the presentations need missing), it says what to do, and compiling goes on: the
  sandbox only needs them to run a VM. `MWT_NATIVE_BUILD=0` skips this step.

  It also says when `priv/microsandbox` holds another msb than
  `scripts/microsandbox.pin` builds (its `VERSION`), which it doesn't
  build: that takes minutes, through `scripts/install-runtime.sh` or
  `scripts/build-microsandbox.sh`. No runtime at all says nothing.

  The code reloader of the development server doesn't run it (its
  `:reloadable_compilers`), so a page never waits for Cargo.
  """

  use Mix.Task.Compiler

  @programs [
    {"native/mwt_relay", "scripts/build-relay.sh", "mwt-relay"},
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
      check_runtime(root, out)
      if :ok in built, do: {:ok, []}, else: {:noop, []}
    end
  end

  defp check_runtime(root, out) do
    script = Path.join(root, "scripts/build-microsandbox.sh")

    with {:ok, built} <- File.read(Path.join(out, "VERSION")),
         true <- File.regular?(script),
         {pinned, 0} <- System.cmd("bash", [script, "--version"], stderr_to_stdout: true),
         warning when is_binary(warning) <- runtime_warning(built, pinned) do
      Mix.shell().error(warning)
    end
  end

  @doc false
  # What to say when the runtime's VERSION isn't the one the pin builds.
  @spec runtime_warning(String.t(), String.t()) :: String.t() | nil
  def runtime_warning(built, pinned) do
    {built, pinned} = {String.trim(built), String.trim(pinned)}

    if built != pinned do
      "==> priv/microsandbox holds msb #{built}, scripts/microsandbox.pin says #{pinned}: " <>
        "MWT runs that one until ./scripts/install-runtime.sh (or " <>
        "./scripts/build-microsandbox.sh) builds it."
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
