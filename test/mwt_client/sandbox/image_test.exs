defmodule MWTClient.Sandbox.ImageTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Build, Image}

  doctest Image

  defp build(name, tag, minutes_ago) do
    %Build{
      ref: "#{name}:#{tag}",
      name: name,
      tag: tag,
      built_at: DateTime.add(~U[2026-11-12 12:00:00Z], -minutes_ago * 60, :second)
    }
  end

  test "tags count builds per day and per name" do
    builds = [build("box", "2026-11-12.1", 30), build("box", "2026-11-12.2", 10)]

    assert Image.next_tag("box", ~D[2026-11-12], builds) == "2026-11-12.3"
    assert Image.next_tag("box", ~D[2026-11-13], builds) == "2026-11-13.1"
    assert Image.next_tag("other", ~D[2026-11-12], builds) == "2026-11-12.1"
  end

  test "the newest three builds are kept, and the VM's even when older" do
    builds = for n <- 1..5, do: build("box", "2026-11-12.#{n}", 60 - n)

    {kept, removed} = Image.keep(builds, [])
    assert Enum.map(kept, & &1.tag) == ["2026-11-12.5", "2026-11-12.4", "2026-11-12.3"]
    assert Enum.map(removed, & &1.tag) == ["2026-11-12.2", "2026-11-12.1"]

    {kept, removed} = Image.keep(builds, ["box:2026-11-12.1"])
    assert "2026-11-12.1" in Enum.map(kept, & &1.tag)
    assert Enum.map(removed, & &1.tag) == ["2026-11-12.2"]
  end

  test "image names follow OCI's rules" do
    assert Image.valid_name?("mwt_agent_sdb_image")
    assert Image.valid_name?("box-2.v1")
    refute Image.valid_name?("Box")
    refute Image.valid_name?("box_")
    refute Image.valid_name?("box:tag")
    refute Image.valid_name?("")
  end

  test "MWT's final layer only points at /mnt/mwt and /cache" do
    layer = Image.final_layer()
    assert layer =~ "/mnt/mwt/ca-bundle.pem"
    assert layer =~ "BASH_ENV=/mnt/mwt/profile.sh"
    assert layer =~ "MISE_DATA_DIR=/cache/mise"
    refute layer =~ "COPY"
  end

  test "podman builds MWT's base, your layer and MWT's final layer, one FROM in all" do
    full = Image.full("RUN echo mine")

    assert [{:base, base}, {:yours, yours}, {:final, final}] = Image.parts("RUN echo mine")
    assert full == Enum.join([base, yours, final], "\n\n") <> "\n"
    assert [_one] = Regex.scan(~r/^FROM /m, full)
    assert base =~ "FROM docker.io/library/ubuntu:26.04"
    assert yours =~ ~r/\A# ---- Your layer.*\nRUN echo mine\z/
    # The final layer runs as root, checks MWT's needs before anything else,
    # and lists the checksums last, once every file is in place.
    assert final =~ "\nUSER root\n"
    assert final =~ "your layer removed or replaced them"
    assert final |> String.split("RUN ") |> List.last() =~ "/etc/mwt/image.sha256"
    assert final =~ ~s(graphroot = "/cache/containers/storage")
  end

  test "the default layer has no FROM, and keeps what MWT's base installs to the base" do
    layer = Image.default_layer()
    assert Image.layer_problem(layer) == nil
    refute Image.whole_containerfile?(layer)
    assert layer =~ "podman podman-docker nftables"
    assert Image.layer_problem("FROM ubuntu:26.04\nRUN true") =~ "no FROM line"
  end

  test "the build reads what podman left without running the image" do
    dir = Path.join(System.tmp_dir!(), "image-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "versions.txt"), "erlang 29.1.2\n")
    File.write!(Path.join(dir, "size"), "4510000000\n")

    build =
      Image.read_build(dir, %{
        name: "box",
        tag: "2026-11-12.1",
        layer: "RUN x",
        containerfile: Image.full("RUN x"),
        built_at: ~U[2026-11-12 12:00:00Z]
      })

    assert build.ref == "box:2026-11-12.1"
    assert build.layer == "RUN x"
    assert build.containerfile =~ "FROM docker.io/library/ubuntu"
    assert build.versions =~ "erlang"
    assert build.size == 4_510_000_000
    script = Image.build_script(dir, build.ref)
    assert script =~ "--format docker --pull=newer --tag"
    assert Image.build_script(dir, build.ref, cache: false) =~ "--pull=always --no-cache --tag"
    # Loaded by the confined msb, let read the archive and nothing else.
    assert script =~ ~s(MWT_MSB_READ='#{dir}/image.tar' "$MWT_MSB" load --input)
  end
end
