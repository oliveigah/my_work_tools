defmodule MWTClient.Sandbox.CredentialScopeTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Grant, Inbox}

  setup do
    inbox = Path.join(System.tmp_dir!(), "credential-scope-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(inbox) end)

    github = %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      state: :on,
      placeholder: "ghp_github_placeholder",
      env: ["GITHUB_TOKEN", "GH_TOKEN"],
      file_env: ["GH_TOKEN_FILE"],
      hosts: ["github.com", "api.github.com"],
      git: true
    }

    other = %Grant{
      github
      | id: "other",
        placeholder: "other_placeholder",
        env: ["OTHER_TOKEN"],
        file_env: [],
        hosts: ["other.example"]
    }

    grants = [github, other]
    Inbox.write(inbox, grants, "")

    # Use the installed CLI and profile together, as the VM does. No
    # inherited credentials or shell startup files from this test runner.
    profile =
      File.read!(Path.join(inbox, "profile.sh"))
      |> String.replace("/mnt/mwt", inbox)

    File.write!(Path.join(inbox, "test-profile.sh"), profile)

    env = [
      {"BASH_ENV", Path.join(inbox, "test-profile.sh")},
      {"GITHUB_TOKEN", nil},
      {"GH_TOKEN", nil},
      {"GH_TOKEN_FILE", nil},
      {"OTHER_TOKEN", nil},
      {"MWT_TOKEN_GRANT", nil}
    ]

    %{inbox: inbox, grants: grants, github: github, env: env}
  end

  defp exec(context, args, options \\ []) do
    System.cmd(
      Path.join(context.inbox, "bin/mwt"),
      ["exec" | args],
      Keyword.merge([env: context.env, stderr_to_stdout: true], options)
    )
  end

  test "an editor's environment probe advertises no credentials with grants on or off", context do
    for state <- [:off, :on] do
      grants = Enum.map(context.grants, &%{&1 | state: state})
      Inbox.write(context.inbox, grants, "")

      for flag <- ["-c", "-lc"] do
        assert {"anonymous\n", 0} =
                 System.cmd(
                   "bash",
                   [
                     "--noprofile",
                     flag,
                     ~S"""
                     test "${GITHUB_TOKEN+x}" != x || exit 10
                     test "${GH_TOKEN+x}" != x || exit 11
                     test "${OTHER_TOKEN+x}" != x || exit 12
                     echo anonymous
                     """
                   ],
                   env: context.env
                 )
      end

      refute File.read!(Path.join(context.inbox, "env.sh")) =~ "export "
    end
  end

  test "only the selected command gets token and token-file variables, including child shells",
       context do
    for flag <- ["-c", "-lc"] do
      assert {"selected\n", 0} =
               exec(context, [
                 "github",
                 "--",
                 "bash",
                 "--noprofile",
                 flag,
                 ~S"""
                 test "$GITHUB_TOKEN" = ghp_github_placeholder || exit 10
                 test "$GH_TOKEN" = "$GITHUB_TOKEN" || exit 11
                 test "$GH_TOKEN_FILE" = /mnt/mwt/tokens/github || exit 12
                 test "$MWT_TOKEN_GRANT" = github || exit 13
                 test "${OTHER_TOKEN+x}" != x || exit 14
                 echo selected
                 """
               ])
    end
  end

  test "execution preserves arguments, stdin, working directory and exit status", context do
    input = Path.join(context.inbox, "input")
    File.write!(input, "from stdin\n")

    script = ~S"""
    test "$1" = 'spaces $HOME `false`' || exit 10
    test "$2" = --reason || exit 11
    test "$PWD" = "$3" || exit 12
    read -r line <&0
    test "$line" = 'from stdin' || exit 13
    echo preserved
    exit 42
    """

    # System.cmd has no stdin option. The outer shell supplies it unchanged.
    assert {"preserved\n", 42} =
             System.cmd(
               "bash",
               [
                 "-c",
                 ~S(exec "$1" exec github -- bash -c "$2" child 'spaces $HOME `false`' --reason "$3" < "$4"),
                 "outer",
                 Path.join(context.inbox, "bin/mwt"),
                 script,
                 context.inbox,
                 input
               ],
               env: context.env,
               cd: context.inbox
             )
  end

  test "an off, expired or deleted grant cannot launch a credential-bearing command", context do
    for grant <- [
          %{context.github | state: :off},
          %{context.github | expires_at: ~U[2000-01-01 00:00:00Z]}
        ] do
      Inbox.write(context.inbox, [grant], "")
      assert {message, 125} = exec(context, ["github", "--", "echo", "must not run"])
      assert message =~ "grant is off"
      refute message =~ "must not run"
    end

    Inbox.write(context.inbox, [], "")
    assert {message, 125} = exec(context, ["github", "--", "echo", "must not run"])
    assert message =~ "no token grant"
    refute File.exists?(Path.join(context.inbox, "grant-env/github.sh"))
  end

  test "a grant a gating check holds off is not exported, whatever its switch says", context do
    [github, other] = context.grants
    # As the server's live_grants shows a grant its check holds off.
    Inbox.write(context.inbox, [%{github | state: :off, held_by: "the VPN is up"}, other], "")
    assert {message, 125} = exec(context, ["github", "--", "echo", "must not run"])
    assert message =~ "grant is off"
    assert {"ran\n", 0} = exec(context, ["other", "--", "echo", "ran"])
  end

  test "a grant only its subgrants use leaves nothing in the VM; mwt exec names its subgrants",
       context do
    only = %{context.github | reach: :subgrants}

    call = %Grant{
      id: "pr-view",
      name: "pr view",
      kind: :request,
      parent: "github",
      method: "GET",
      url: "https://api.github.com/x"
    }

    Inbox.write(context.inbox, [only, call], "")
    refute File.exists?(Path.join(context.inbox, "tokens/github"))
    refute File.exists?(Path.join(context.inbox, "git/github"))
    refute File.read!(Path.join(context.inbox, "grant-env/github.sh")) =~ only.placeholder

    assert {message, 125} = exec(context, ["github", "--", "echo", "must not run"])
    assert message =~ "github is only for its subgrants"
    assert message =~ "mwt call pr-view"
    refute message =~ "must not run"
  end

  test "a grant's Google login file holds only placeholders, and only its command is told of it",
       context do
    login = %{
      context.github
      | id: "cli",
        placeholder: "ya29.mwt_cli_placeholder",
        env: [],
        file_env: [],
        hosts: ["*.googleapis.com"],
        git: false,
        presents: %{login: %{refresh: "1//mwt_cli_login", header: ""}}
    }

    Inbox.write(context.inbox, [login], "")

    assert %{
             "type" => "authorized_user",
             "refresh_token" => "1//mwt_cli_login",
             "client_id" => "32555940559.apps.googleusercontent.com"
           } = context.inbox |> Path.join("logins/cli.json") |> File.read!() |> Jason.decode!()

    assert {output, 0} =
             exec(context, ["cli", "--", "bash", "-c", "echo $GOOGLE_APPLICATION_CREDENTIALS"])

    assert String.trim(output) == "/mnt/mwt/logins/cli.json"

    # Outside it, nothing names it; without the presentation, no file.
    {plain, 0} =
      System.cmd("bash", ["-c", "echo -n $GOOGLE_APPLICATION_CREDENTIALS"], env: context.env)

    assert plain == ""

    Inbox.write(context.inbox, [%{login | presents: %{}}], "")
    refute File.exists?(Path.join(context.inbox, "logins/cli.json"))
  end

  @tag :present
  test "a grant's metadata server serves its placeholder for the command's lifetime", context do
    %Grant{} = github = context.github

    gcp = %{
      github
      | id: "gcp",
        placeholder: "ya29.mwt_gcp_placeholder",
        env: [],
        file_env: [],
        hosts: ["*.googleapis.com"],
        git: false,
        presents: %{
          metadata: %{project: "my-project", email: "sa@my-project.iam.gserviceaccount.com"}
        }
    }

    Inbox.write(context.inbox, [gcp], "")
    # Tests have a runtime folder of their own: the one this checkout built.
    File.cp!(
      Path.expand("../../../priv/microsandbox/bin/mwt-present", __DIR__),
      Path.join(context.inbox, "bin/mwt-present")
    )

    curl = ~S(curl -s -H "Metadata-Flavor: Google" "http://$GCE_METADATA_HOST/computeMetadata/v1/)

    script =
      curl <>
        ~S(instance/service-accounts/default/token"; echo; ) <>
        ~S(env | grep -c ^MWT_PRESENT; echo "$GCE_METADATA_HOST" > "$1"; exit 7)

    port_file = Path.join(context.inbox, "port")

    assert {output, 7} =
             exec(
               context,
               [
                 "gcp",
                 "--",
                 "bash",
                 "-c",
                 script,
                 "x",
                 port_file
               ],
               cd: context.inbox
             )

    assert output =~ ~s("access_token":"ya29.mwt_gcp_placeholder")
    assert output =~ ~r/\n0\n/

    # Nothing listens once the command ended.
    [_host, port] = port_file |> File.read!() |> String.trim() |> String.split(":")
    assert {:error, _} = :gen_tcp.connect(~c"127.0.0.1", String.to_integer(port), [], 500)
  end

  test "activation is visible to the next scoped command without a new shell", context do
    Inbox.write(context.inbox, [%{context.github | state: :off}], "")
    assert {_, 125} = exec(context, ["github", "--", "true"])
    Inbox.write(context.inbox, [context.github], "")
    assert {"", 0} = exec(context, ["github", "--", "true"])
  end

  test "invalid invocations never run a tool or source paths outside the grant folder", context do
    for args <- [
          [],
          ["../env", "--", "false"],
          ["github"],
          ["github", "--"],
          ["github", "false"],
          ["github", "--help", "false"]
        ] do
      assert {message, 125} = exec(context, args)
      assert message =~ "mwt exec GRANT_ID -- COMMAND"
    end
  end

  test "a refusal is told from the command's own status: the command's exit passes through",
       context do
    assert {"", 3} = exec(context, ["github", "--", "sh", "-c", "exit 3"])
    assert {"", 1} = exec(context, ["github", "--", "false"])
    assert {_, 125} = exec(context, ["nope", "--", "true"])
  end

  test "nested, a command gets both grants, and git is answered for each one's hosts", context do
    helper = Path.join(context.inbox, "bin/git-credential")
    input = Path.join(context.inbox, "git-input")
    command = ~S("$1" get < "$2")
    mwt = Path.join(context.inbox, "bin/mwt")

    for {host, placeholder} <- [
          {"github.com", "ghp_github_placeholder"},
          {"other.example", "other_placeholder"}
        ] do
      File.write!(input, "protocol=https\nhost=#{host}\n\n")

      assert {output, 0} =
               exec(context, [
                 "github",
                 "--",
                 mwt,
                 "exec",
                 "other",
                 "--",
                 "bash",
                 "-c",
                 ~S(test "$GH_TOKEN" = ghp_github_placeholder && test "$OTHER_TOKEN" = other_placeholder && test "$MWT_TOKEN_GRANT" = github,other && ) <>
                   command,
                 "helper",
                 helper,
                 input
               ])

      assert output =~ "password=#{placeholder}\n", host
    end
  end

  test "git's helper supplies only the selected grant, and nothing to ordinary git", context do
    helper = Path.join(context.inbox, "bin/git-credential")
    input = Path.join(context.inbox, "git-input")

    for host <- ["github.com", "other.example", "../tokens/github"] do
      File.write!(input, "protocol=https\nhost=#{host}\n\n")
      command = ~S("$1" get < "$2")

      assert {plain, 0} =
               System.cmd("bash", ["-c", command, "helper", helper, input],
                 env: context.env,
                 stderr_to_stdout: true
               )

      # Nothing for ordinary git; for a host a grant covers, how to use it.
      refute plain =~ "password="

      case host do
        "github.com" -> assert plain =~ "mwt exec github -- git"
        "other.example" -> assert plain =~ "mwt exec other -- git"
        _not_a_grant_host -> assert plain == ""
      end

      assert {output, 0} =
               exec(context, ["github", "--", "bash", "-c", command, "helper", helper, input])

      # Only the selected grant's own hosts: another grant's host gets no
      # credential, only how to add that grant.
      if host == "github.com" do
        assert output =~ "password=#{context.github.placeholder}\n"
      else
        refute output =~ "password="
      end
    end
  end
end
