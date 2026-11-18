defmodule MWTClient.Sandbox.SharesTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Share, Shares}

  setup do
    root = Path.join(System.tmp_dir!(), "shares-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    data = Path.join(home, ".mwt_client")

    for dir <- ["projects/app/lib", "projects/other", ".ssh", ".config/gcloud", ".mwt_client"] do
      File.mkdir_p!(Path.join(home, dir))
    end

    File.write!(Path.join(home, "projects/notes.txt"), "")
    on_exit(fn -> File.rm_rf!(root) end)
    %{home: home, opts: [home: home, data_dir: data]}
  end

  test "shares a project folder by its resolved path", %{home: home, opts: opts} do
    assert {:ok, %Share{path: path}} =
             Shares.validate("~/projects/app", [], opts)

    assert path == Path.join(home, "projects/app")
  end

  test "refuses credential folders, folders holding them, home and root", %{
    home: home,
    opts: opts
  } do
    assert {:error, {:refused, _, "SSH keys"}} = Shares.validate("~/.ssh", [], opts)

    assert {:error, {:refused, _, "Google Cloud credentials"}} =
             Shares.validate(Path.join(home, ".config"), [], opts)

    assert {:error, {:refused, _, "MWT's own data"}} =
             Shares.validate("~/.mwt_client", [], opts)

    assert {:error, :home} = Shares.validate("~", [], opts)
    assert {:error, :root} = Shares.validate("/", [], opts)
  end

  test "resolves symlinks before judging, so a link can't smuggle a refused folder in",
       %{home: home, opts: opts} do
    link = Path.join(home, "projects/app/keys")
    File.ln_s!(Path.join(home, ".ssh"), link)

    assert {:error, {:refused, folder, "SSH keys"}} = Shares.validate(link, [], opts)
    assert folder == Path.join(home, ".ssh")
  end

  test "refuses overlaps either way, and the same folder reached another way",
       %{home: home, opts: opts} do
    app = %Share{path: Path.join(home, "projects/app")}

    assert {:error, {:overlaps, _}} = Shares.validate("~/projects/app/lib", [app], opts)
    assert {:error, {:overlaps, _}} = Shares.validate("~/projects", [app], opts)
    assert {:error, :duplicate} = Shares.validate("~/projects/other/../app", [app], opts)
    assert {:ok, _} = Shares.validate("~/projects/other", [app], opts)
  end

  test "a repository may be shared, a folder inside one not", %{home: home, opts: opts} do
    app = Path.join(home, "projects/app")
    {_, 0} = System.cmd("git", ["-C", app, "init", "-q"])

    assert {:ok, %Share{path: ^app}} = Shares.validate(app, [], opts)

    assert {:error, {:inside_repository, ^app}} =
             Shares.validate(Path.join(app, "lib"), [], opts)

    assert Shares.explain({:inside_repository, app}) =~ "Share the repository instead"
  end

  test "refuses where the VM keeps its own disks", %{opts: opts} do
    for path <- ["/work", "/cache", "/root", "/mnt"] do
      if File.dir?(path),
        do: assert({:error, {:vm_path, ^path}} = Shares.validate(path, [], opts))
    end

    assert Shares.explain({:vm_path, "/work"}) =~ "/work"
  end

  test "refuses what is not a folder", %{opts: opts} do
    assert {:error, :blank} = Shares.validate("  ", [], opts)
    assert {:error, :not_absolute} = Shares.validate("projects/app", [], opts)
    assert {:error, :missing} = Shares.validate("~/projects/gone", [], opts)
    assert {:error, :not_a_folder} = Shares.validate("~/projects/notes.txt", [], opts)
  end

  test "explains every refusal in a sentence" do
    for reason <- [
          :blank,
          :not_absolute,
          :missing,
          :not_a_folder,
          :loop,
          :root,
          :home,
          :duplicate
        ] do
      assert Shares.explain(reason) =~ "."
    end

    assert Shares.explain({:overlaps, "/a"}) =~ "/a"
    assert Shares.explain({:refused, "/h/.ssh", "SSH keys"}) =~ "SSH keys"
  end
end
