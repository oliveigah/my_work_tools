defmodule MWTClient.UpdatesTest do
  use ExUnit.Case, async: true

  alias MWTClient.Updates

  @moduletag :tmp_dir

  test "startup leaves the updater idle" do
    assert {:ok, %{status: :idle, package: nil, task: nil}} = Updates.init(nil)
  end

  @release_tag "v0.8.0"
  @downloads "https://github.com/oliveigah/my_work_tools/releases/download/v0.8.0/"

  defp release_json(names) do
    %{
      "tag_name" => @release_tag,
      "assets" => Enum.map(names, &%{"name" => &1, "browser_download_url" => @downloads <> &1})
    }
  end

  describe "select_release/3" do
    test "takes a newer release carrying the package, its sums and their signature" do
      json = release_json(["MWT_0.8.0.deb", "MWT_0.8.0.rpm", "SHA256SUMS", "SHA256SUMS.sig"])

      assert {:ok, release} = Updates.select_release(json, "0.7.0", :rpm)

      assert release == %{
               version: "0.8.0",
               name: "MWT_0.8.0.rpm",
               format: :rpm,
               package_url: @downloads <> "MWT_0.8.0.rpm",
               sums_url: @downloads <> "SHA256SUMS",
               signature_url: @downloads <> "SHA256SUMS.sig"
             }
    end

    test "is current for the version running and older ones" do
      json = release_json(["MWT_0.8.0.deb", "SHA256SUMS", "SHA256SUMS.sig"])

      assert :current = Updates.select_release(json, "0.8.0", :deb)
      assert :current = Updates.select_release(json, "0.10.0", :deb)
    end

    test "refuses a newer release without a signature or without this install's package" do
      unsigned = release_json(["MWT_0.8.0.deb", "SHA256SUMS"])

      assert {:error, "MWT 0.8.0 is out, but its release has no signed .deb package yet."} =
               Updates.select_release(unsigned, "0.7.0", :deb)

      deb_only = release_json(["MWT_0.8.0.deb", "SHA256SUMS", "SHA256SUMS.sig"])

      assert {:error, "MWT 0.8.0 is out, but its release has no signed .rpm package yet."} =
               Updates.select_release(deb_only, "0.7.0", :rpm)
    end

    test "takes assets only from the release's own downloads" do
      json = release_json(["MWT_0.8.0.deb", "SHA256SUMS", "SHA256SUMS.sig"])

      elsewhere =
        update_in(json["assets"], fn assets ->
          Enum.map(assets, fn asset ->
            Map.update!(asset, "browser_download_url", &String.replace(&1, "oliveigah", "other"))
          end)
        end)

      assert {:error, _} = Updates.select_release(elsewhere, "0.7.0", :deb)
    end

    test "says when it can't read the release" do
      assert {:error, "Could not read the version of the latest release: nightly."} =
               Updates.select_release(%{"tag_name" => "nightly", "assets" => []}, "0.7.0", :deb)

      assert {:error, "Could not read the latest release."} =
               Updates.select_release(%{"message" => "Not Found"}, "0.7.0", :deb)
    end
  end

  test "finds a package's exact line in the release's checksums" do
    hash = String.duplicate("ab", 32)

    sums = """
    #{String.duplicate("cd", 32)}  ./MWT_0.8.0.rpm
    #{String.upcase(hash)}  ./MWT_0.8.0.deb
    """

    assert {:ok, ^hash} = Updates.checksum(sums, "MWT_0.8.0.deb")
    assert :error = Updates.checksum(sums, "MWT_0.8.deb")
    assert :error = Updates.checksum("short  ./MWT_0.8.0.deb\n", "MWT_0.8.0.deb")
  end

  describe "the release key" do
    test "reads one Ed25519 public key from its PEM" do
      {public, _private} = :crypto.generate_key(:eddsa, :ed25519)
      assert {:ok, ^public} = Updates.decode_key(public_pem(public))
    end

    test "refuses any other key or text" do
      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = rsa

      rsa_pem =
        :public_key.pem_encode([
          :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, modulus, exponent})
        ])

      assert :error = Updates.decode_key(rsa_pem)
      assert :error = Updates.decode_key("not a key")
      assert :error = Updates.decode_key("")
    end

    test "verifies the checksums it signed, and nothing else" do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      {other, _private} = :crypto.generate_key(:eddsa, :ed25519)
      sums = "#{String.duplicate("ab", 32)}  ./MWT_0.8.0.deb\n"
      signature = sign(sums, private)

      assert Updates.signed?(sums, signature, public)
      refute Updates.signed?(sums <> " ", signature, public)
      refute Updates.signed?(sums, signature, other)
      refute Updates.signed?(sums, binary_part(signature, 0, 63), public)
      refute Updates.signed?(sums, nil, public)
    end
  end

  describe "latest_release/3" do
    test "weighs the latest release GitHub describes" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/repos/oliveigah/my_work_tools/releases/latest"
        Req.Test.json(conn, release_json(["MWT_0.8.0.deb", "SHA256SUMS", "SHA256SUMS.sig"]))
      end)

      assert {:ok, %{version: "0.8.0", name: "MWT_0.8.0.deb"}} =
               Updates.latest_release(:deb, "0.7.0", plug: {Req.Test, __MODULE__})

      assert :current = Updates.latest_release(:deb, "0.8.0", plug: {Req.Test, __MODULE__})
    end

    test "says when there is no release, or GitHub can't be asked" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 404, ~s({"message":"Not Found"})))

      assert {:error, "No MWT release is published yet."} =
               Updates.latest_release(:deb, "0.7.0", plug: {Req.Test, __MODULE__})

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 403, "rate limited"))

      assert {:error, "Could not check for updates. Please try again."} =
               Updates.latest_release(:deb, "0.7.0", plug: {Req.Test, __MODULE__})
    end
  end

  describe "download_release/4" do
    setup do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      %{key: public, private: private}
    end

    test "refuses checksums the release key didn't sign", %{key: key} do
      {_other, private} = :crypto.generate_key(:eddsa, :ed25519)
      package = "a package"
      sums = sums_for("MWT_0.8.0.deb", package)
      serve_release(%{"SHA256SUMS" => sums, "SHA256SUMS.sig" => sign(sums, private)}, package)

      assert {:error,
              "The release's checksums aren't signed with MWT's release key, so it wasn't installed."} =
               download(key)
    end

    test "refuses a package that doesn't match its checksum", %{key: key, private: private} do
      sums = sums_for("MWT_0.8.0.deb", "the package that was signed")
      serve_release(%{"SHA256SUMS" => sums, "SHA256SUMS.sig" => sign(sums, private)}, "another")

      assert {:error,
              "The downloaded package doesn't match its release checksum, so it wasn't installed."} =
               download(key)
    end

    test "refuses checksums that don't list the package", %{key: key, private: private} do
      sums = sums_for("MWT_0.8.0.rpm", "a package")
      serve_release(%{"SHA256SUMS" => sums, "SHA256SUMS.sig" => sign(sums, private)}, "a package")

      assert {:error, "The release's checksums don't list MWT_0.8.0.deb."} = download(key)
    end

    test "says when a file can't be downloaded", %{key: key} do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 404, "Not Found"))

      assert {:error, "The update could not be downloaded. Please try again."} = download(key)
    end

    @tag :dpkg
    test "keeps a signed, matching MWT package, in a folder only you open",
         %{key: key, private: private, tmp_dir: tmp_dir} do
      package = File.read!(build_deb!(tmp_dir, "mwt", "0.8.0"))
      sums = sums_for("MWT_0.8.0.deb", package)
      serve_release(%{"SHA256SUMS" => sums, "SHA256SUMS.sig" => sign(sums, private)}, package)

      assert {:ok, downloaded} = download(key)
      assert %{version: "0.8.0", file: "MWT_0.8.0.deb", format: :deb} = downloaded
      assert File.read!(downloaded.path) == package
      assert Path.dirname(downloaded.path) == downloaded.dir
      assert %File.Stat{mode: mode} = File.stat!(downloaded.dir)
      assert Bitwise.band(mode, 0o777) == 0o700

      File.rm_rf!(downloaded.dir)
    end

    @tag :dpkg
    test "refuses a signed package holding another version than its release",
         %{key: key, private: private, tmp_dir: tmp_dir} do
      package = File.read!(build_deb!(tmp_dir, "mwt", "0.9.0"))
      sums = sums_for("MWT_0.8.0.deb", package)
      serve_release(%{"SHA256SUMS" => sums, "SHA256SUMS.sig" => sign(sums, private)}, package)

      assert {:error, "The downloaded package isn't MWT 0.8.0, so it wasn't installed."} =
               download(key)
    end
  end

  defp download(key) do
    {:ok, release} =
      Updates.select_release(
        release_json(["MWT_0.8.0.deb", "SHA256SUMS", "SHA256SUMS.sig"]),
        "0.7.0",
        :deb
      )

    Updates.download_release(release, "0.7.0", key, plug: {Req.Test, __MODULE__})
  end

  defp serve_release(files, package) do
    files = Map.put(files, "MWT_0.8.0.deb", package)

    Req.Test.stub(__MODULE__, fn conn ->
      "/oliveigah/my_work_tools/releases/download/v0.8.0/" <> name = conn.request_path
      Plug.Conn.send_resp(conn, 200, Map.fetch!(files, name))
    end)
  end

  defp sums_for(name, package) do
    "#{Base.encode16(:crypto.hash(:sha256, package), case: :lower)}  ./#{name}\n"
  end

  defp sign(sums, private), do: :crypto.sign(:eddsa, :none, sums, [private, :ed25519])

  defp public_pem(public) do
    :public_key.pem_encode([
      :public_key.pem_entry_encode(
        :SubjectPublicKeyInfo,
        {{:ECPoint, public}, {:namedCurve, {1, 3, 101, 112}}}
      )
    ])
  end

  describe "verdict/3" do
    test "takes MWT newer than the one running" do
      assert {:ok, "0.7.0"} = Updates.verdict("mwt", "0.7.0", "0.6.0")
      assert {:ok, "1.0.0"} = Updates.verdict("mwt", "1.0.0", "0.10.3")
      assert {:ok, "0.10.0"} = Updates.verdict("mwt", "0.10.0", "0.9.0")
    end

    test "refuses the version running and older ones" do
      assert {:error, "This package is MWT 0.6.0, the version you have."} =
               Updates.verdict("mwt", "0.6.0", "0.6.0")

      assert {:error, "This package is MWT 0.5.9, older than the 0.6.0 you have."} =
               Updates.verdict("mwt", "0.5.9", "0.6.0")
    end

    test "refuses another package and a version it can't read" do
      assert {:error, "This is the package curl, not MWT."} =
               Updates.verdict("curl", "9.0.0", "0.6.0")

      assert {:error, "Could not read the version of this package: 0.7.0~rc1."} =
               Updates.verdict("mwt", "0.7.0~rc1", "0.6.0")
    end
  end

  test "reads the name and version dpkg-deb and rpm print" do
    assert {:ok, "mwt", "0.7.0"} = Updates.package_fields("Package: mwt\nVersion: 0.7.0\n")

    assert {:ok, "mwt", "0.7.0"} =
             Updates.package_fields("warning: NOKEY\nPackage: mwt\nVersion: 0.7.0\n")

    assert :error = Updates.package_fields("Package: mwt\n")
    assert :error = Updates.package_fields("")
  end

  describe "read_package/3" do
    test "refuses what isn't a package file", %{tmp_dir: tmp_dir} do
      text = Path.join(tmp_dir, "notes.deb")
      File.write!(text, "not a package")

      assert {:error, "This file is not a .deb package."} =
               Updates.read_package(text, :deb, "0.6.0")

      assert {:error, "Choose a package file."} = Updates.read_package(tmp_dir, :deb, "0.6.0")

      assert {:error, "Could not open the file: no such file or directory."} =
               Updates.read_package(Path.join(tmp_dir, "gone.deb"), :deb, "0.6.0")
    end

    @tag :dpkg
    test "reads a copy of a newer MWT package, in a folder only you open", %{tmp_dir: tmp_dir} do
      picked = build_deb!(tmp_dir, "mwt", "0.7.0")

      assert {:ok, package} = Updates.read_package(picked, :deb, "0.6.0")
      assert %{version: "0.7.0", file: "MWT_0.7.0.deb", format: :deb} = package

      # What gets installed is the copy MWT read, not the file picked.
      File.rm!(picked)
      assert File.regular?(package.path)
      assert Path.dirname(package.path) == package.dir
      assert %File.Stat{mode: mode} = File.stat!(package.dir)
      assert Bitwise.band(mode, 0o777) == 0o700

      File.rm_rf!(package.dir)
    end

    @tag :rpmbuild
    test "reads the name and version of an .rpm", %{tmp_dir: tmp_dir} do
      assert {:ok, %{version: "0.7.0", format: :rpm} = package} =
               Updates.read_package(build_rpm!(tmp_dir, "mwt", "0.7.0"), :rpm, "0.6.0")

      File.rm_rf!(package.dir)

      assert {:error, "This is the package other, not MWT."} =
               Updates.read_package(build_rpm!(tmp_dir, "other", "0.7.0"), :rpm, "0.6.0")
    end

    @tag :dpkg
    test "keeps no copy of a package it refuses", %{tmp_dir: tmp_dir} do
      older = build_deb!(tmp_dir, "mwt", "0.5.0")
      other = build_deb!(tmp_dir, "other", "9.0.0")
      before = update_dirs()

      assert {:error, "This package is MWT 0.5.0, older than the 0.6.0 you have."} =
               Updates.read_package(older, :deb, "0.6.0")

      assert {:error, "This is the package other, not MWT."} =
               Updates.read_package(other, :deb, "0.6.0")

      assert leftovers(before, [File.read!(older), File.read!(other)]) == []
    end
  end

  defp build_deb!(tmp_dir, name, version) do
    root = Path.join(tmp_dir, "#{name}-#{version}")
    File.mkdir_p!(Path.join(root, "DEBIAN"))

    File.write!(Path.join([root, "DEBIAN", "control"]), """
    Package: #{name}
    Version: #{version}
    Architecture: amd64
    Maintainer: MWT tests <tests@example.com>
    Description: A package for the updater's tests
    """)

    deb = Path.join(tmp_dir, "MWT_#{version}.deb")

    {_output, 0} =
      System.cmd("dpkg-deb", ["--build", "--root-owner-group", root, deb], stderr_to_stdout: true)

    deb
  end

  defp build_rpm!(tmp_dir, name, version) do
    top = Path.join(tmp_dir, "rpm-#{name}-#{version}")
    spec = Path.join(tmp_dir, "#{name}.spec")

    File.write!(spec, """
    Name: #{name}
    Version: #{version}
    Release: 5
    Summary: A package for the updater's tests
    License: MIT
    BuildArch: noarch

    %description
    A package for the updater's tests.

    %files
    """)

    {_output, 0} =
      System.cmd("rpmbuild", ["-bb", "--define", "_topdir #{top}", spec], stderr_to_stdout: true)

    Path.join([top, "RPMS", "noarch", "#{name}-#{version}-5.noarch.rpm"])
  end

  defp update_dirs do
    System.tmp_dir!() |> Path.join("mwt-update-*") |> Path.wildcard() |> MapSet.new()
  end

  # The temporary folder is the machine's: another run may be reading
  # packages too, so only a copy of these packages is a leftover.
  defp leftovers(before, packages) do
    for dir <- MapSet.difference(update_dirs(), before),
        {:ok, bytes} <- [File.read(Path.join(dir, "MWT.deb"))],
        bytes in packages,
        do: dir
  end
end
