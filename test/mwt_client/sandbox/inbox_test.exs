defmodule MWTClient.Sandbox.InboxTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{CertificateAuthority, Grant, Inbox, Instructions}

  test "the inbox carries everything the image points at" do
    dir = Path.join(System.tmp_dir!(), "inbox-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ca = CertificateAuthority.new() |> Map.fetch!(:cert) |> CertificateAuthority.pem()

    grant = %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      purpose: "Push to my repos",
      placeholder: "ghp_placeholder",
      env: ["GH_TOKEN"],
      file_env: ["GH_TOKEN_FILE"],
      git: true,
      hosts: ["github.com", "*.github.com"]
    }

    # Where file grants, gone since, wrote real values: emptied.
    File.mkdir_p!(Path.join(dir, "files"))
    File.write!(Path.join(dir, "files/kubeconfig"), "ghp_real")

    :ok = Inbox.write(dir, [grant], ca)
    refute File.exists?(Path.join(dir, "files"))

    assert File.read!(Path.join(dir, "ca.pem")) == ca
    assert String.ends_with?(File.read!(Path.join(dir, "ca-bundle.pem")), ca)

    # The same roots, for a JVM.
    assert File.read!(Path.join(dir, "java-truststore.jks")) ==
             MWTClient.Sandbox.JavaTrust.store(File.read!(Path.join(dir, "ca-bundle.pem")))

    refute File.read!(Path.join(dir, "env.sh")) =~ "export "
    assert File.read!(Path.join(dir, "grant-env/github.sh")) =~ "return 125"
    assert File.read!(Path.join(dir, "tokens/github")) == "ghp_placeholder"
    refute File.read!(Path.join(dir, "profile.sh")) =~ ". /mnt/mwt/env.sh"
    assert File.read!(Path.join(dir, "bashrc.sh")) =~ "/mnt/mwt/profile.sh"

    for command <- ["bin/git-credential", "bin/mwt", "bin/git-remote-mwt"] do
      assert %File.Stat{mode: mode} = File.stat!(Path.join(dir, command))
      assert Bitwise.band(mode, 0o111) != 0
    end

    assert File.read!(Path.join(dir, "AGENTS.md")) =~ "Access comes only from MWT"
    assert File.read!(Path.join(dir, "grants.md")) =~ "## GitHub"
    assert File.read!(Path.join(dir, "git/github")) == "github.com\n"
    assert File.ls!(Path.join(dir, "git")) == ["github"]

    for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true), File.regular?(file) do
      refute File.read!(file) =~ "ghp_real", "#{file} holds the real value"
    end

    refute File.read!(Path.join(dir, "agents-block.md")) =~ "way of working"
  end

  test "the guides are in the inbox, and mwt help prints them" do
    dir = Path.join(System.tmp_dir!(), "inbox-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    # A guide MWT no longer has goes; the others are written.
    File.mkdir_p!(Path.join(dir, "guides"))
    File.write!(Path.join(dir, "guides/gone.md"), "old")
    :ok = Inbox.write(dir, [], "")

    guides = Instructions.guides()

    assert File.ls!(Path.join(dir, "guides")) |> Enum.sort() ==
             Enum.sort(Map.keys(guides) |> Enum.map(&(&1 <> ".md")))

    mwt = Path.join(dir, "bin/mwt")
    assert {handoff, 0} = System.cmd(mwt, ["help", "handoff"])
    assert handoff == guides["handoff"]

    assert {usage, 0} = System.cmd(mwt, ["help"])

    assert usage =~
             "Guides, mwt help TOPIC: #{guides |> Map.delete("timeline") |> Map.keys() |> Enum.sort() |> Enum.join(" ")}\n"

    for topic <- ["gone", "nope", "../AGENTS"] do
      assert {said, 1} = System.cmd(mwt, ["help", topic], stderr_to_stdout: true)
      assert said =~ "mwt: there is no guide #{topic}. Guides: access handoff"
    end
  end

  test "the user's way of working joins the agents' instructions" do
    dir = Path.join(System.tmp_dir!(), "inbox-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ca = CertificateAuthority.new() |> Map.fetch!(:cert) |> CertificateAuthority.pem()
    way = "Keep answers short."

    :ok = Inbox.write(dir, [], ca, way_of_working: way)

    assert File.read!(Path.join(dir, "AGENTS.md")) == Instructions.text(way_of_working: way)

    assert File.read!(Path.join(dir, "agents-block.md")) ==
             Instructions.block(way_of_working: way)
  end
end
