defmodule MWTClient.Sandbox.LayerVersionsTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Image, LayerVersions, Settings}

  setup do
    MWTClient.VaultHelpers.unlocked_identity("layers")
  end

  test "every save keeps the layer it replaced; one that changes nothing keeps nothing",
       %{username: username} do
    first = %Settings{image_layer: "RUN echo one\n"}

    second =
      LayerVersions.change(username, first, %{first | image_layer: "RUN echo two\n"}, :you, :edit)

    assert second.image_layer_version == 2
    assert %DateTime{} = second.image_layer_saved_at

    # At once again: a layer saves only when you say so, so no quiet time.
    third =
      LayerVersions.change(
        username,
        second,
        %{second | image_layer: "RUN echo three\n"},
        :you,
        :edit
      )

    same = LayerVersions.change(username, third, third, :you, :edit)
    assert same.image_layer_version == 3

    assert [%{version: 2} = two, %{version: 1} = one] = LayerVersions.list(username)
    assert LayerVersions.text(two) == "RUN echo two\n"
    assert LayerVersions.text(one) == "RUN echo one\n"
    assert {:ok, ^one} = LayerVersions.fetch(username, 1)
  end

  test "a whole Containerfile from before is kept as a version, and you start on MWT's default",
       %{username: username} do
    old = "FROM docker.io/library/ubuntu:26.04\nRUN apt-get install -y htop\n"
    settings = %Settings{image_layer: Image.default_layer()}

    upgraded = LayerVersions.upgrade(username, settings, old)
    assert upgraded.image_layer == Image.default_layer()
    assert [%{replaced_by: :mwt} = kept] = versions = LayerVersions.list(username)
    assert LayerVersions.text(kept) == old
    assert LayerVersions.upgraded?(upgraded, versions)

    # Once you save, the page stops saying so.
    saved =
      LayerVersions.change(
        username,
        upgraded,
        %{upgraded | image_layer: "RUN true\n"},
        :you,
        :edit
      )

    refute LayerVersions.upgraded?(saved, LayerVersions.list(username))

    # A layer already without a FROM, or none at all, stays as it is.
    assert LayerVersions.upgrade(username, saved, "RUN true\n") == saved
    assert LayerVersions.upgrade(username, saved, nil) == saved
  end
end
