defmodule MWTClient.Sandbox.InboxTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{CertificateAuthority, Grant, Inbox}

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
  end
end
