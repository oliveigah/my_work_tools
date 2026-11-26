defmodule MWTClient.ReleaseTest do
  @moduledoc """
  How the packaged release starts: never as an Erlang node. With
  distribution on, any program reaching epmd that holds the cookie runs
  code inside MWT, and the cookie is the same in every copy of a package
  and readable by everyone on the machine.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # `bin/mwt_client` sources the rendered `env.sh` before it fills in its
  # defaults, so what it exports is what the release starts with.
  test "the release starts with distribution off, whatever the environment asks for" do
    template = Path.join(@root, "rel/env.sh.eex")
    script = EEx.eval_file(template, assigns: %{release: %{name: :mwt_client}})

    dir = Path.join(System.tmp_dir!(), "mwt-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> MWTClient.TestFolders.remove!(dir) end)
    File.write!(Path.join(dir, "env.sh"), script)

    assert {"none\n", 0} =
             System.cmd("sh", ["-c", ~s(. "$1"/env.sh; echo "$RELEASE_DISTRIBUTION"), "sh", dir],
               env: [{"RELEASE_DISTRIBUTION", "sname"}]
             )
  end

  # The package build copies only what it names into the stages that
  # compile: without these, a package would start as a node again, or lack
  # MWT's NIF.
  test "both package builds copy the release's settings and MWT's NIF" do
    stages =
      Path.join(@root, "scripts/linux-packages.Dockerfile")
      |> File.read!()
      |> String.split(~r/^FROM /m)

    for name <- ["deb-build", "rpm-build"] do
      assert [stage] = Enum.filter(stages, &String.contains?(hd(String.split(&1, "\n")), name))

      for line <- ["COPY rel ./rel", "COPY Makefile ./", "COPY c_src ./c_src"],
          do: assert(stage =~ line, "#{name} lacks #{line}")
    end
  end

  test "the package build context includes the release settings and native sources" do
    allowed = @root |> Path.join(".dockerignore") |> File.read!() |> String.split("\n")

    for pattern <- ["!Makefile", "!c_src/", "!c_src/**", "!rel/", "!rel/**"],
        do: assert(pattern in allowed)
  end
end
