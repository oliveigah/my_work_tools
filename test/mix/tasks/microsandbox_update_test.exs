defmodule Mix.Tasks.Microsandbox.UpdateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Microsandbox.Update

  @pin Path.expand("../../../scripts/microsandbox.pin", __DIR__)

  test "the pin is read by key, and rewritten with only the values given changed" do
    text = File.read!(@pin)
    pin = Update.parse_pin(text)

    assert %{"UPSTREAM" => _, "REVISION" => revision, "LIBKRUNFW" => "libkrunfw.so." <> _} = pin
    assert byte_size(revision) == 40

    for key <-
          ~w(AGENTD_SHA256_X86_64 AGENTD_SHA256_AARCH64 LIBKRUNFW_SHA256_X86_64 LIBKRUNFW_SHA256_AARCH64),
        do: assert(pin[key] =~ ~r/\A[0-9a-f]{64}\z/, key)

    moved = Update.put_pin(text, %{"UPSTREAM" => "9.9.9", "KERNEL" => "abc"})
    assert Update.parse_pin(moved) == %{pin | "UPSTREAM" => "9.9.9", "KERNEL" => "abc"}
    # Comments and blank lines stay as they were.
    assert String.split(moved, "\n") |> Enum.reject(&(&1 =~ ~r/\A(UPSTREAM|KERNEL)=/)) ==
             String.split(text, "\n") |> Enum.reject(&(&1 =~ ~r/\A(UPSTREAM|KERNEL)=/))

    assert_raise Mix.Error, ~r/no NEW_KEY/, fn -> Update.put_pin(text, %{"NEW_KEY" => "x"}) end
  end

  test "the build script reads the same pin, and every key it names is there" do
    script = File.read!(Path.expand("../../../scripts/build-microsandbox.sh", __DIR__))
    pin = @pin |> File.read!() |> Update.parse_pin()

    for [_, key] <- Regex.scan(~r/\$\{?([A-Z][A-Z0-9_]+)/, script),
        key in ~w(REPOSITORY UPSTREAM REVISION LIBKRUN_VERSION LIBKRUN_SOURCE LIBKRUNFW KERNEL) or
          String.ends_with?(key, ["_X86_64", "_AARCH64"]),
        do: assert(Map.has_key?(pin, key), key)

    {version, 0} =
      System.cmd("bash", [
        Path.expand("../../../scripts/build-microsandbox.sh", __DIR__),
        "--version"
      ])

    assert String.trim(version) == "#{pin["UPSTREAM"]}+#{String.slice(pin["REVISION"], 0, 9)}"
  end

  test "what the source says: libkrun from Cargo.lock, the kernel's file name, its commit" do
    lock = """
    [[package]]
    name = "msb_krun_utils"
    version = "0.1.46"

    [[package]]
    name = "msb_krun"
    version = "0.1.46"
    source = "git+https://github.com/superradcompany/libkrun?rev=77cad8a1#77cad8a1"
    dependencies = [
    """

    utils = ~s(pub const LIBKRUNFW_VERSION: &str = "5.6.1";\n)

    assert Update.source_facts(lock, utils, "f0493b6f") == %{
             "LIBKRUN_VERSION" => "0.1.46",
             "LIBKRUN_SOURCE" =>
               "git+https://github.com/superradcompany/libkrun?rev=77cad8a1#77cad8a1",
             "LIBKRUNFW" => "libkrunfw.so.5.6.1",
             "KERNEL" => "f0493b6f"
           }

    assert_raise Mix.Error, ~r/which libkrunfw/, fn -> Update.source_facts(lock, "", "x") end
  end

  test "the digests come from the release's files, and a file that's gone is refused" do
    hex = String.duplicate("a", 64)

    files = %{
      "agentd-x86_64" => "sha256:" <> hex,
      "agentd-aarch64" => "sha256:" <> hex,
      "libkrunfw-linux-x86_64.so" => "sha256:" <> hex,
      "libkrunfw-linux-aarch64.so" => "sha256:" <> hex,
      "msb-linux-x86_64" => "sha256:" <> hex
    }

    assert Update.digests!(files, "v1.0.0") |> Map.values() |> Enum.uniq() == [hex]
    assert map_size(Update.digests!(files, "v1.0.0")) == 4

    assert_raise Mix.Error, ~r/v1.0.0 has no agentd-aarch64/, fn ->
      Update.digests!(Map.delete(files, "agentd-aarch64"), "v1.0.0")
    end
  end

  test "commits are told apart: breaking, security fixes, and their type" do
    log =
      "a1\x1ffeat(lifecycle)!: unify snapshots\x1f\x1e\n" <>
        "b2\x1fMerge commit from fork\x1f* fix(network): refuse local DNS names\n\nmore\x1e\n" <>
        "c3\x1ffix(cli): use the stop budget\x1fBREAKING CHANGE: restart waits\x1e\n" <>
        "d4\x1ffix(sdk): decode statuses\x1f\x1e\n" <>
        "e5\x1fMy Work Tools\x1f\x1e\n"

    assert Update.commits(log) == [
             %{hash: "a1", subject: "feat(lifecycle)!: unify snapshots", kind: :breaking},
             %{
               hash: "b2",
               subject: "security fix: fix(network): refuse local DNS names",
               kind: :security
             },
             %{hash: "c3", subject: "fix(cli): use the stop budget", kind: :breaking},
             %{hash: "d4", subject: "fix(sdk): decode statuses", kind: "fix"},
             %{hash: "e5", subject: "My Work Tools", kind: "other"}
           ]
  end

  test "added lines that call what the seccomp filter refuses are found, others aren't" do
    diff = """
    diff --git a/crates/runtime/lib/a.rs b/crates/runtime/lib/a.rs
    +++ b/crates/runtime/lib/a.rs
    +    let fd = unsafe { libc::syscall(libc::SYS_userfaultfd, 0) };
    +    nix::mount::mount(None::<&str>, "/x", None::<&str>, flags, None::<&str>)?;
    -    libc::bpf(0);
    +    let mount_point = "/mnt"; // --mount-disk
    +    rustix::process::pidfd_open(pid)?;
    +++ b/crates/cli/lib/b.rs
    +    libc::ptrace(libc::PTRACE_ATTACH, pid, 0, 0);
    """

    assert Update.denied_calls(diff, [:userfaultfd, :mount, :bpf, :ptrace]) == [
             {"crates/runtime/lib/a.rs",
              "let fd = unsafe { libc::syscall(libc::SYS_userfaultfd, 0) };"},
             {"crates/runtime/lib/a.rs",
              ~s{nix::mount::mount(None::<&str>, "/x", None::<&str>, flags, None::<&str>)?;}},
             {"crates/cli/lib/b.rs", "libc::ptrace(libc::PTRACE_ATTACH, pid, 0, 0);"}
           ]
  end

  test "the notes: changelogs after the old release up to the new one, guides of minors crossed" do
    paths = ~w(
      docs/changelog/v0.7.14.mdx docs/changelog/v0.7.15.mdx docs/changelog/v0.7.16.mdx
      docs/changelog/v0.8.0.mdx docs/changelog/v0.8.3.mdx docs/changelog/2026-04-03.mdx
      docs/migrations/overview.mdx docs/migrations/v0.7.mdx docs/migrations/v0.8.mdx docs/migrations/v0.9.mdx
    )

    assert Update.notes(paths, Version.parse!("0.7.15"), Version.parse!("0.8.2")) ==
             ~w(docs/changelog/v0.7.16.mdx docs/changelog/v0.8.0.mdx docs/migrations/v0.8.mdx)

    assert Update.notes(paths, Version.parse!("0.7.15"), Version.parse!("0.7.16")) ==
             ~w(docs/changelog/v0.7.16.mdx)
  end

  test "what to look at first follows from what changed" do
    old = %{
      "KERNEL" => "k1",
      "LIBKRUNFW" => "libkrunfw.so.5.6.1",
      "LIBKRUN_SOURCE" => "registry+https://github.com/rust-lang/crates.io-index"
    }

    assert Update.first_looks(old, old, [], [], []) == []

    new = %{
      old
      | "KERNEL" => "k2",
        "LIBKRUN_SOURCE" => "git+https://github.com/x/libkrun?rev=1#1"
    }

    commits = [%{kind: :breaking}, %{kind: :security}, %{kind: :security}, %{kind: "fix"}]

    looks = Update.first_looks(old, new, commits, ["crates/migration/lib/m3.rs"], [{"a.rs", "x"}])

    assert Enum.map(looks, &(&1 |> String.split("**") |> Enum.at(1))) == [
             "The kernel changed under the same file name",
             "libkrun comes from elsewhere:",
             "The store's migrations changed",
             "1 breaking change",
             "2 security fixes",
             "1 added line makes a call MWT's seccomp filter refuses"
           ]
  end

  test "an older release than the pin's is refused" do
    assert_raise Mix.Error, ~r/older than the pin's/, fn -> Update.run(["0.0.1"]) end
  end
end
