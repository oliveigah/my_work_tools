defmodule MWTClient.Sandbox.MsbContractTest do
  # What MWT asks of microsandbox, checked against the msb in
  # priv/microsandbox, with no VM: every flag of every command MWT runs
  # (MWTClient.Sandbox.Msb.Commands) is one that msb's help lists, and the
  # answers MWT reads say what MWT reads in them. `mix test --only msb`,
  # after ./scripts/install-runtime.sh; the `vm` tests check what only a
  # running VM shows.
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Msb
  alias MWTClient.Sandbox.Msb.Commands

  @moduletag :msb
  @moduletag :tmp_dir

  @vm "mwt-contract"

  setup_all do
    runtime = Application.app_dir(:mwt_client, "priv/microsandbox")
    msb = Path.join(runtime, "bin/msb")
    File.regular?(msb) || flunk("No msb in #{runtime}: run ./scripts/install-runtime.sh")

    {pinned, 0} =
      System.cmd("bash", [
        Path.expand("../../../scripts/build-microsandbox.sh", __DIR__),
        "--version"
      ])

    pinned = String.trim(pinned)
    built = runtime |> Path.join("VERSION") |> File.read!() |> String.trim()

    built == pinned ||
      flunk(
        "priv/microsandbox holds msb #{built}, the pin says #{pinned}: run ./scripts/install-runtime.sh"
      )

    # Not `msb`: the module tag puts `msb: true` in the context.
    %{program: msb, pinned: pinned}
  end

  setup %{tmp_dir: dir} do
    %{home: Path.join(dir, "msb"), user_home: Path.join(dir, "home")}
  end

  # Each command MWT runs, after the words that name it in msb's help.
  defp commands do
    vm = %{
      name: @vm,
      image: "box:1",
      cpus: 2,
      memory_gib: 8,
      disk_gib: 40,
      shell: "/bin/bash",
      env: [{"MWT_X", "1"}],
      nested_virt: true
    }

    [
      {["create"], Commands.create(vm)},
      {["start"], Commands.start(@vm)},
      {["stop"], Commands.stop(@vm)},
      {["modify"], Commands.resize_memory(@vm, 4096)},
      {["modify"], Commands.boot_memory(@vm, 4, 8)},
      {["modify"], Commands.remove_env(@vm, ["MWT_X"])},
      {["exec"], Commands.exec(@vm, ["true"])},
      {["exec"], Commands.exec_stream(@vm, ["true"])},
      {["inspect"], Commands.inspect_vm(@vm)},
      {["image", "inspect"], Commands.inspect_image("box:1")},
      {["image", "remove"], Commands.remove_images(["box:1", "localhost/box:1"])},
      {["load"], Commands.load("/tmp/image.tar", "box:1")},
      {["ssh", "serve"], Commands.ssh_serve(@vm)},
      {["ssh", "authorize"], Commands.ssh_authorize_file("/tmp/key.pub")},
      {["ssh", "authorize"], Commands.ssh_authorize_stdin()}
    ]
  end

  # msb with its own home, nothing of this machine's, as MWT runs it.
  defp msb(context, args) do
    System.cmd(context.program, args,
      env: [
        {"MSB_HOME", context.home},
        {"MSB_PATH", context.program},
        {"MSB_BACKEND", "local"},
        {"NO_COLOR", "1"},
        {"HOME", context.user_home}
      ],
      stderr_to_stdout: true
    )
  end

  test "every flag MWT passes is one msb's help lists", context do
    missing =
      Enum.flat_map(commands(), fn {words, args} ->
        assert List.starts_with?(args, words)
        command = "msb " <> Enum.join(words, " ")

        case msb(context, words ++ ["--help"]) do
          {help, 0} ->
            for flag <- flags(args), not listed?(help, flag), do: "#{command}: no #{flag}"

          {help, status} ->
            ["#{command} --help failed (#{status}): #{String.slice(help, 0, 200)}"]
        end
      end)

    assert Enum.uniq(missing) == []
  end

  test "it is the pinned release", context do
    {version, 0} = msb(context, ["--version"])
    [upstream, _commit] = String.split(context.pinned, "+")
    assert String.trim(version) == "msb #{upstream}"
  end

  test "a VM that doesn't exist is told apart from a failure (Msb.status/2)", context do
    {output, status} = msb(context, Commands.inspect_vm(@vm))
    assert status != 0
    assert Msb.not_found?(output), output
  end

  test "an image that isn't loaded is a failure (Msb.image?/2)", context do
    {_output, status} = msb(context, Commands.inspect_image("mwt-contract-missing:1"))
    assert status != 0
  end

  test "msb keeps what it makes in MSB_HOME, never in your home", context do
    File.mkdir_p!(context.user_home)
    {_output, _status} = msb(context, Commands.inspect_vm(@vm))
    assert File.ls!(context.home) != []
    assert File.ls!(context.user_home) == []
  end

  test "the VM's process is `msb machine`, which the relay and Bubble look for", context do
    {help, status} = msb(context, ["machine", "--help"])
    assert status == 0, help
    assert listed?(help, "--name")
  end

  # The flags of a command line, before any `--` that ends them.
  defp flags(args) do
    args
    |> Enum.take_while(&(&1 != "--"))
    |> Enum.filter(&String.starts_with?(&1, "--"))
    |> Enum.map(&(&1 |> String.split("=") |> hd()))
  end

  defp listed?(help, flag), do: help =~ ~r/(^|[\s,])#{Regex.escape(flag)}([\s=,<\[]|$)/m
end
