defmodule MWTClient.Sandbox.CopyBackTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{CopyBack, Guest, Secrets, Workspace}

  doctest CopyBack

  @token "ghp_" <> String.duplicate("q", 36)

  # A workspace here, and a folder of this machine standing in for the VM,
  # whose from-vm is on its work disk.
  setup do
    base = Path.join(System.tmp_dir!(), "copy-back-#{System.unique_integer([:positive])}")
    root = Path.join(base, "home/mwt-vm")
    vm = Path.join(base, "vm")
    File.mkdir_p!(Workspace.from_vm(root))
    File.chmod!(Workspace.from_vm(root), 0o555)
    File.mkdir_p!(vm <> Workspace.vm_store())

    on_exit(fn ->
      System.cmd("chmod", ["-R", "u+w", base])
      File.rm_rf!(base)
    end)

    %{
      base: base,
      root: root,
      here: Workspace.from_vm(root),
      store: vm <> Workspace.vm_store(),
      guest: Guest.local(vm),
      dir: Path.join(base, "data")
    }
  end

  defp put(context, path, bytes) do
    full = Path.join(context.store, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
  end

  defp run(context, record \\ nil, opts \\ []) do
    CopyBack.run(
      record || CopyBack.new("vm-test"),
      context.guest,
      context.root,
      Keyword.merge([dir: context.dir], opts)
    )
  end

  defp mode(path), do: File.lstat!(path).mode |> Bitwise.band(0o777)

  # Everything under `root`, relative, sorted: what MWT wrote there.
  defp listing(root) do
    Path.wildcard(Path.join(root, "**"), match_dot: true)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  test "files and folders come here, read-only, and nowhere else", context do
    put(context, "report.md", "# Report\n")
    put(context, "out/entry.yaml", "key: value\n")
    File.mkdir_p!(Path.join(context.store, "empty"))
    File.chmod!(Path.join(context.store, "report.md"), 0o755)

    assert {record, nil} = run(context)
    assert %{error: nil, written: 2, removed: 0, files: 2} = record.status

    assert File.read!(Path.join(context.here, "report.md")) == "# Report\n"
    assert File.read!(Path.join(context.here, "out/entry.yaml")) == "key: value\n"
    assert File.dir?(Path.join(context.here, "empty"))
    # Never executable, and nothing of it writable here.
    assert mode(Path.join(context.here, "report.md")) == 0o444
    assert mode(Path.join(context.here, "out")) == 0o555
    assert mode(context.here) == 0o555

    # Only from-vm changed: the staging folder is gone.
    assert listing(context.root) ==
             ~w(from-vm from-vm/empty from-vm/out from-vm/out/entry.yaml from-vm/report.md)
  end

  test "what the VM removed goes here, and so does a file added here", context do
    put(context, "a.txt", "a")
    put(context, "sub/b.txt", "b")
    {record, nil} = run(context)

    File.rm!(Path.join(context.store, "a.txt"))
    File.rm_rf!(Path.join(context.store, "sub"))
    File.chmod!(context.here, 0o755)
    File.write!(Path.join(context.here, "mine.txt"), "mine")

    assert {record, nil} = run(context, record)
    assert record.status.removed == 4
    assert listing(context.here) == []
  end

  test "nothing changed brings nothing; a file changed here comes again", context do
    put(context, "a.txt", "from the VM")
    {record, nil} = run(context)

    assert {record, nil} = run(context, record)
    assert %{written: 0, removed: 0} = record.status

    file = Path.join(context.here, "a.txt")
    File.chmod!(file, 0o644)
    File.write!(file, "changed here")

    assert {record, nil} = run(context, record)
    assert record.status.written == 1
    assert File.read!(file) == "from the VM"

    # What was brought is kept for the VM: a new record knows it.
    assert {fresh, nil} = run(context)
    assert fresh.status.written == 0
  end

  test "a file the VM changed comes again", context do
    put(context, "a.txt", "one")
    {record, nil} = run(context)
    put(context, "a.txt", "two, longer")

    assert {record, nil} = run(context, record)
    assert record.status.written == 1
    assert File.read!(Path.join(context.here, "a.txt")) == "two, longer"
  end

  test "an archive larger than the files asked for lands nothing", context do
    put(context, "a.txt", "small")

    # The pack, and only it, sends more than the files it was asked for.
    guest = %{
      context.guest
      | stream: fn words ->
          if Enum.any?(words, &String.contains?(&1, "tar -c")),
            do: ["sh", "-c", "cat >/dev/null; head -c 200000 /dev/zero"],
            else: context.guest.stream.(words)
        end
    }

    assert {record, nil} = run(%{context | guest: guest})
    assert record.status.error =~ "larger than the files asked for"
    assert listing(context.here) == []
  end

  # msb writes its own database while it streams the archive: only the
  # archive is held to the size of what was asked for.
  test "what the command writes elsewhere doesn't count against the archive", context do
    put(context, "a.txt", "small")
    side = Path.join(context.base, "side.db")

    guest = %{
      context.guest
      | stream: fn words ->
          ["sh", "-c", ~s(head -c 300000 /dev/zero > "$0"; shift; exec "$@"), side, "--" | words]
        end
    }

    assert {record, nil} = run(%{context | guest: guest})
    assert record.status.error == nil
    assert File.read!(Path.join(context.here, "a.txt")) == "small"
    assert File.stat!(side).size == 300_000
  end

  describe "an entry breaking a rule lands nothing" do
    for {name, make, why} <- [
          {"a symlink", :link, "symlink"},
          {"a .git folder", {:file, "repo/.git/config", "[core]\n\tfsmonitor = sh -c x\n"},
           "dot"},
          {"a .envrc", {:file, ".envrc", "curl x | sh\n"}, "dot"},
          {"a name starting with -", {:file, "--checkpoint-action=exec=sh x", "x"}, "option"},
          {"mise.toml", {:file, "tools/mise.toml", "[env]\n"}, "mise"},
          {"a control character", {:file, "bad\nname", "x"}, "control character"},
          {"a FIFO", :fifo, "isn't a file or a folder"}
        ] do
      test name, context do
        put(context, "good.txt", "good")

        case unquote(Macro.escape(make)) do
          :link -> File.ln_s!("/etc/passwd", Path.join(context.store, "passwd"))
          :fifo -> {_, 0} = System.cmd("mkfifo", [Path.join(context.store, "pipe")])
          {:file, path, bytes} -> put(context, path, bytes)
        end

        assert {record, nil} = run(context)
        assert record.status.error =~ "Nothing of from-vm came"
        assert record.status.error =~ unquote(why)
        assert listing(context.here) == []
      end
    end
  end

  test "a file holding a grant's real value lands nothing, and says which", context do
    put(context, "good.txt", "good")
    # Across two of the chunks it is read in.
    put(context, "leak.txt", String.duplicate("x", 1024 * 1024 - 10) <> @token <> "\n")
    secrets = Secrets.new([{{:value, "GitHub"}, Secrets.forms(@token)}])

    assert {record, {:value, "GitHub", "leak.txt"}} = run(context, nil, secrets: secrets)
    assert record.status.error =~ "leak.txt holds GitHub's real value"
    assert listing(context.here) == []
    refute File.exists?(Workspace.stage(context.root))
  end

  test "a link here is removed as a link, never followed", context do
    outside = Path.join(context.base, "outside")
    File.mkdir_p!(outside)
    File.chmod!(context.here, 0o755)
    File.ln_s!(outside, Path.join(context.here, "sub"))
    put(context, "sub/x.txt", "x")

    assert {record, nil} = run(context)
    assert record.status.error == nil
    assert File.read!(Path.join(context.here, "sub/x.txt")) == "x"
    assert File.lstat!(Path.join(context.here, "sub")).type == :directory
    assert File.ls!(outside) == []
    assert mode(outside) == 0o755
  end

  test "the caps: entries and bytes" do
    many = Map.new(1..20_001, &{"f#{&1}", {:file, 1, 0}})
    assert {:error, {:too_big, :entries}} = CopyBack.check(many)

    big = %{"a" => {:file, 1024 * 1024 * 1024, 0}, "b" => {:file, 1, 0}}
    assert {:error, {:too_big, :bytes}} = CopyBack.check(big)
    assert CopyBack.explain({:too_big, :bytes}) =~ "more than 1 GiB"
  end

  test "names that don't show, too long, or too deep" do
    assert CopyBack.path_problem("a" <> <<0x202E::utf8>> <> "txt.sh") =~ "don't show"
    assert CopyBack.path_problem(String.duplicate("n", 256)) =~ "longer than 255"
    assert CopyBack.path_problem(Enum.map_join(1..33, "/", fn _ -> "d" end)) =~ "32 folders deep"
    assert CopyBack.path_problem(<<"caf", 0xE9>>) =~ "UTF-8"
    assert CopyBack.path_problem("mise/config.toml") =~ "mise"
    assert CopyBack.path_problem("mise.local.toml") =~ "mise"
    assert CopyBack.path_problem("reports/mise-notes.toml") == nil
  end
end
