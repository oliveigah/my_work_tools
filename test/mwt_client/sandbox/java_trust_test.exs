defmodule MWTClient.Sandbox.JavaTrustTest do
  @moduledoc """
  The truststore a JVM in the VM trusts MWT's CA through, read back the
  way Java reads a JKS file (`sun.security.provider.JavaKeyStore`). Tried
  on 2026-11-22 against Temurin 21: `keytool -list` reads it, refuses it
  under another password, and Java's HTTP client trusts a host whose
  certificate MWT's CA signed, and a public one, through it.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.JavaTrust

  # The entries of a JKS store, and whether its integrity check holds
  # for `password`.
  defp read(store, password) do
    size = byte_size(store) - 20
    <<body::binary-size(^size), digest::binary-20>> = store
    <<0xFEEDFEED::32, 2::32, count::32, entries::binary>> = body

    utf16 = for <<char <- password>>, into: "", do: <<0, char>>
    intact? = :crypto.hash(:sha, [utf16, "Mighty Aphrodite", body]) == digest

    {certificates, ""} =
      Enum.map_reduce(1..count//1, entries, fn _, rest ->
        <<2::32, name_size::16, name::binary-size(name_size), _added::64, 5::16, "X.509",
          der_size::32, der::binary-size(der_size), rest::binary>> = rest

        {{name, der}, rest}
      end)

    {certificates, intact?}
  end

  defp pem(ders), do: Enum.map_join(ders, &CA.pem/1)

  test "it holds every certificate of the bundle, in order, once, its integrity checked" do
    ders = for name <- ["One", "Two", "Three"], do: CA.new(name).cert
    [one, two, three] = ders

    {entries, intact?} = read(JavaTrust.store(pem(ders ++ [two])), "changeit")
    assert intact?
    assert entries == [{"root-1", one}, {"root-2", two}, {"root-3", three}]

    # The password the options name is the one it checks against.
    assert JavaTrust.options() =~ "-Djavax.net.ssl.trustStorePassword=changeit"
    assert {_entries, false} = read(JavaTrust.store(pem(ders)), "another")

    # The same roots make the same file, so writing it again changes nothing.
    assert JavaTrust.store(pem(ders)) == JavaTrust.store(pem(ders))
  end

  test "the image points every JVM at it, with the options MWT means" do
    layer = MWTClient.Sandbox.Image.final_layer()
    assert layer =~ ~s(JAVA_TOOL_OPTIONS="#{JavaTrust.options()}")
    assert JavaTrust.options() =~ "-Djavax.net.ssl.trustStore=/mnt/mwt/java-truststore.jks"
  end
end
