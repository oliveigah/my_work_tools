defmodule MWTClient.Sandbox.JavaTrust do
  @moduledoc """
  The roots the VM trusts (`ca-bundle.pem`: this machine's, and MWT's CA),
  as a truststore a JVM reads. Pure.

  A JVM reads neither the system's bundle nor `SSL_CERT_FILE`: it trusts
  the `cacerts` file of its own install, which a JDK from mise brings with
  it. So once MWT reads a host, Gradle, Maven or any other JVM program
  would refuse MWT's certificate there. MWT writes the same roots in the
  format a JVM reads, `/mnt/mwt/java-truststore.jks`, and the image points
  every JVM at it with `JAVA_TOOL_OPTIONS` (`options/0`), which each JVM
  says on stderr as it starts ("Picked up JAVA_TOOL_OPTIONS"). It goes
  with the CA, as the bundle does: nothing in the image changes when the
  CA does.

  The format is JKS, Java's own: every JVM since Java 1.2 reads it (one
  asked for PKCS12 reads it too), and it is simple enough to write here,
  with no `keytool` on this machine. Big-endian, as `DataOutputStream`
  writes it:

    * `0xFEEDFEED`, version 2, the number of entries;
    * each a trusted certificate: tag 2, an alias (a length and its
      bytes), when it was added (milliseconds; 0 here, so the same roots
      make the same file), `X.509`, the certificate's length and its DER;
    * a SHA-1 of the password (each character as two bytes), the words
      `Mighty Aphrodite`, and all the above: the store's integrity check,
      against the password the options name. The password guards nothing:
      a truststore holds no key.
  """

  @password "changeit"
  @path "/mnt/mwt/java-truststore.jks"

  @doc "The truststore holding every certificate in `pem`, in its order."
  @spec store(binary()) :: binary()
  def store(pem) do
    certificates =
      for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), uniq: true, do: der

    entries =
      certificates
      |> Enum.with_index(1)
      |> Enum.map(fn {der, n} -> entry("root-#{n}", der) end)

    body = IO.iodata_to_binary([<<0xFEEDFEED::32, 2::32, length(entries)::32>> | entries])
    body <> :crypto.hash(:sha, [utf16(@password), "Mighty Aphrodite", body])
  end

  @doc "What the image sets `JAVA_TOOL_OPTIONS` to: where the truststore is, its format and password."
  @spec options() :: String.t()
  def options do
    "-Djavax.net.ssl.trustStore=#{@path} -Djavax.net.ssl.trustStoreType=JKS " <>
      "-Djavax.net.ssl.trustStorePassword=#{@password}"
  end

  defp entry(name, der),
    do: [<<2::32>>, text(name), <<0::64>>, text("X.509"), <<byte_size(der)::32>>, der]

  # Java's modified UTF-8, which for ASCII is the bytes themselves.
  defp text(ascii), do: <<byte_size(ascii)::16, ascii::binary>>

  defp utf16(ascii), do: for(<<char <- ascii>>, into: "", do: <<0, char>>)
end
