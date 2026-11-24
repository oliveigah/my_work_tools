defmodule MWTClient.Sandbox.ImageCheckTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Guest, ImageCheck}

  doctest ImageCheck

  # An image's files and the checksum list MWT's final layer makes, in a
  # folder of this machine standing in for the VM's image disk.
  setup do
    base = Path.join(System.tmp_dir!(), "image-check-#{System.unique_integer([:positive])}")
    image = Path.join(base, "image")
    File.mkdir_p!(Path.join(image, "usr/local/bin"))
    File.mkdir_p!(Path.join(image, "etc/mwt"))
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)

    File.write!(Path.join(image, "usr/local/bin/tool"), :binary.copy("x", 300_000))
    File.write!(Path.join(image, "etc/hostname-of-image"), "box\n")

    {_, 0} =
      System.cmd("sh", [
        "-c",
        ~S(cd "$1" && find . -type f ! -path ./etc/mwt/image.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > etc/mwt/image.sha256),
        "make-list",
        image
      ])

    %{guest: Guest.local(base), image: image}
  end

  test "an image whose files are as built is intact", %{guest: guest, image: image} do
    assert ImageCheck.run(guest, image) == :intact
  end

  test "a file that reads as zeros past its start is named", %{guest: guest, image: image} do
    tool = Path.join(image, "usr/local/bin/tool")
    File.write!(tool, :binary.copy("x", 100_000) <> :binary.copy(<<0>>, 200_000))

    assert {:damaged, ["/usr/local/bin/tool"], 1} = ImageCheck.run(guest, image)
    assert ImageCheck.explain({:damaged, ["/usr/local/bin/tool"], 1}) =~ "without podman's cache"
  end

  test "a file gone, and a list itself unreadable, are damage too", %{guest: guest, image: image} do
    File.rm!(Path.join(image, "etc/hostname-of-image"))
    assert {:damaged, ["/etc/hostname-of-image"], 1} = ImageCheck.run(guest, image)

    File.write!(Path.join(image, "etc/mwt/image.sha256"), :binary.copy(<<0>>, 4096))
    assert {:damaged, [], 0} = ImageCheck.run(guest, image)
    assert ImageCheck.explain({:damaged, [], 0}) =~ "checksum list couldn't be read"
  end

  test "an image built before the list is not checked", %{guest: guest, image: image} do
    File.rm!(Path.join(image, "etc/mwt/image.sha256"))
    assert {:unchecked, why} = ImageCheck.run(guest, image)
    assert why =~ "built before MWT made one"
  end
end
