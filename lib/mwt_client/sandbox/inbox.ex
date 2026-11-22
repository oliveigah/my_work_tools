defmodule MWTClient.Sandbox.Inbox do
  @moduledoc """
  What MWT has for the VM, written into a folder here and copied into the
  VM at `/mnt/mwt` (`into_vm/4`): a folder in the VM's memory (tmpfs),
  filled at each start before anything there reads it, and again within
  moments of every change here. Nothing of it is mounted from this
  machine. The image only points here, so everything that belongs to one
  identity or to this version of MWT arrives this way:

    * `ca.pem`, `ca-bundle.pem` - the identity's CA, alone and appended to
      this machine's trusted roots; the image links its system bundle to the
      second;
    * `java-truststore.jks` - the same roots, as a JVM reads them
      (`MWTClient.Sandbox.JavaTrust`), which the image points every JVM at;
    * `profile.sh`, `bashrc.sh`, `env.sh` - the shell's tool paths,
      interactive defaults (no credential exports);
    * `grant-env/<id>.sh` - a token grant's environment, loaded only by
      `mwt exec <id> -- COMMAND` while that grant is on;
    * `bin/mwt` - the command agents ask MWT for access with
      (`MWTClient.Sandbox.Channel`);
    * `bin/git-credential`, `git/<id>` - the hosts a selected token grant
      answers git for; ordinary git commands get no MWT credential;
    * `tokens/<grant>` - each token grant's placeholder, as a file;
    * `logins/<grant>.json` - a Google login file, for a token grant that
      presents one (`login_file/1`): placeholders only;
    * `AGENTS.md`, `grants.md` - what agents are told, and the grants as they
      are now;
    * `guides/<topic>.md` - what only some tasks need, which `mwt help
      TOPIC` prints (`Instructions.guides/0`);
    * `bin/mwt-boot`, `agents-block.md`, `handoff-command.md`, `bin/memo` -
      what the VM copies for itself after each boot: the script MWT runs in
      it, the instructions as a block for the agents' own files, the
      `/handoff` command for them, and your `memo` tool when you have
      OptMem;
    * `bin/mwt-acp` - the ACP shell Zed starts for MWT's agents
      (`MWTClient.Sandbox.AgentThreads`), which `bin/mwt-boot` puts in the
      VM's Zed settings; when this build has it (`scripts/build-acp.sh`);
    * `host.md` - your machine, for writing host commands
      (`MWTClient.Sandbox.HostInfo`), written by `write_host/2`.

  Everything here is worthless outside MWT's proxy: no real value is ever
  written into it. Being in memory, the VM's copy is never on a disk, and
  each start begins without it.

  The VM can change its copy, as anything of its own: that changes nothing
  MWT does, and the next whole comparison puts it back as MWT has it
  (`MWTClient.Sandbox.FolderSync`, `:mwt`, so nothing is set aside).
  """

  alias MWTClient.Sandbox.{FolderSync, Grant, Guest, Instructions, JavaTrust, Memory, Msb}

  @vm "/mnt/mwt"
  # gcloud's OAuth client, public in its source: what a login it made names.
  @gcloud_client_id "32555940559.apps.googleusercontent.com"

  # Run in the VM, as root: makes the folder one in the VM's memory, unless
  # it is already. Over a folder mounted there by a VM made before
  # 2026-11-16, too.
  @mount ~S"""
  grep -qs " $1 tmpfs " /proc/mounts && exit 0
  mkdir -p -- "$1"
  mount -t tmpfs -o mode=0755,nosuid,nodev,size=256m mwt "$1"
  """

  @doc "Where the VM has its copy."
  @spec vm_path() :: Path.t()
  def vm_path, do: @vm

  @doc "A record of the VM's copy of the inbox in `dir`, before any look."
  @spec record(Path.t(), String.t()) :: FolderSync.record()
  def record(dir, vm_id), do: FolderSync.new(dir, vm_id, to: @vm, kind: :mwt)

  @doc """
  One look at the VM's copy (`FolderSync.sync/4`) in the running VM `name`
  of `username`, with what was sent kept in `data`. Before the first look
  after a start, and after a failure, `/mnt/mwt` is made a folder in the
  VM's memory when it isn't one. An error is in the record's status.

  With `fresh: true`, at a start, the folder is new and empty: everything
  goes in with a plain `tar`, so an image without bash or GNU tools gets
  it too, and its boot script (POSIX sh) runs.
  """
  @spec into_vm(FolderSync.record(), String.t(), String.t(), Path.t(), keyword()) ::
          FolderSync.record()
  def into_vm(record, username, name, data, opts \\ []) do
    mounted =
      if record.checked_at == nil,
        do: Msb.run(username, ["exec", name, "--", "sh", "-c", @mount, "mwt-inbox", @vm], 60),
        else: {:ok, ""}

    case mounted do
      {:ok, _} ->
        FolderSync.sync(record, Guest.vm(username, name), data, opts)

      {:error, message} ->
        put_in(record.status.error, "#{@vm} couldn't be made in the VM: #{message}")
    end
  end

  @doc """
  Rewrites the inbox from the grants and the identity's CA certificate.
  `opts` choose the guides that join the agents' instructions
  (`Instructions.text/1`), and `:workspace` is the workspace's folder
  (`MWTClient.Sandbox.Workspace`), which every shell in the VM finds in
  `MWT_WORKSPACE`.
  """
  @spec write(Path.t(), [Grant.t()], String.t(), keyword()) :: :ok
  def write(dir, grants, ca_pem, opts \\ []) do
    File.mkdir_p!(dir)

    put_changed(dir, "ca.pem", ca_pem)
    bundle = bundle(ca_pem)
    put_changed(dir, "ca-bundle.pem", bundle)
    put_changed(dir, "java-truststore.jks", JavaTrust.store(bundle))
    put_changed(dir, "profile.sh", priv("mwt-profile.sh") <> workspace(opts[:workspace]))
    put_changed(dir, "bashrc.sh", priv("mwt-bashrc.sh"))
    put_changed(dir, "bin/git-credential", priv("mwt-git-credential"), 0o755)
    put_changed(dir, "bin/mwt", priv("mwt-cli"), 0o755)
    # git's helper for `mwt::` remotes, each project's clone's `origin`
    # (`MWTClient.Sandbox.Project.remote_url/1`), fetched over the agent channel.
    put_changed(dir, "bin/git-remote-mwt", priv("mwt-git-remote"), 0o755)
    put_changed(dir, "AGENTS.md", Instructions.text(opts))
    # What only some tasks need, which `mwt help TOPIC` prints.
    hold(
      dir,
      "guides",
      Map.new(Instructions.guides(), fn {topic, text} -> {topic <> ".md", {text, 0o644}} end)
    )

    # What the VM copies for itself after each boot (`bin/mwt-boot`): MWT
    # writes nothing into storage the VM can write.
    put_changed(dir, "agents-block.md", Instructions.block(opts))
    put_changed(dir, "handoff-command.md", priv("handoff-command.md"))
    put_changed(dir, "bin/mwt-boot", priv("mwt-boot"), 0o755)

    case Memory.host_memo() do
      nil -> File.rm(Path.join(dir, "bin/memo"))
      memo -> put_changed(dir, "bin/memo", File.read!(memo), 0o755)
    end

    # The ACP shell Zed starts for MWT's agents, when this build has it.
    case acp_shell() do
      nil -> File.rm(Path.join(dir, "bin/mwt-acp"))
      shell -> put_changed(dir, "bin/mwt-acp", File.read!(shell), 0o755)
    end

    # The presentations `mwt exec` runs for a grant that asks for one.
    case presenter() do
      nil -> File.rm(Path.join(dir, "bin/mwt-present"))
      present -> put_changed(dir, "bin/mwt-present", File.read!(present), 0o755)
    end

    # A grant only its subgrants use leaves nothing in the VM: no
    # placeholder, no variable, no file; `mwt exec` names its subgrants.
    {only_subgrants, tokens} =
      grants |> Enum.filter(&(&1.kind == :token)) |> Enum.split_with(&Grant.subgrants_only?/1)

    # Older images/profiles source this file. Leave it inert, rather than
    # removing it while an old shell is starting.
    put_changed(dir, "env.sh", "# Credentials are scoped to mwt exec GRANT -- COMMAND.\n")

    hold(
      dir,
      "grant-env",
      Map.new(tokens, fn grant ->
        script =
          if Grant.on?(grant) do
            env_script([grant]) <> present_script(grant)
          else
            "echo 'mwt: this token grant is off. Run mwt request #{grant.id} --reason \"...\"' >&2\nreturn 125\n"
          end

        {grant.id <> ".sh", {script, 0o644}}
      end)
      |> Map.merge(
        Map.new(only_subgrants, fn grant ->
          {grant.id <> ".sh", {subgrants_only_script(grant, grants), 0o644}}
        end)
      )
    )

    put(dir, "grants.md", Instructions.grants(grants, DateTime.utc_now()))

    hold(
      dir,
      "git",
      for grant <- tokens, hosts = Grant.git_hosts(grant), hosts != [], into: %{} do
        {grant.id, {Enum.join(hosts, "\n") <> "\n", 0o644}}
      end
    )

    hold(dir, "tokens", Map.new(tokens, &{&1.id, {&1.placeholder, 0o644}}))

    hold(
      dir,
      "logins",
      for grant <- tokens, Grant.login_placeholder(grant), into: %{} do
        {grant.id <> ".json", {login_file(grant), 0o644}}
      end
    )

    # Where file grants, gone since 2026-11-18, put their real values.
    File.rm_rf!(Path.join(dir, "files"))

    :ok
  end

  # Makes the folder `sub` hold exactly `wanted` (name => {data, mode}): what
  # is new or changed is written, what is no longer wanted is deleted, and
  # the rest is left alone. A file that stays is never missing, not even for
  # the moment a rewrite of the whole folder would take.
  defp hold(dir, sub, wanted) do
    folder = Path.join(dir, sub)
    File.mkdir_p!(folder)

    for name <- File.ls!(folder),
        not Map.has_key?(wanted, name),
        do: File.rm_rf!(Path.join(folder, name))

    for {name, {data, mode}} <- wanted, do: put_changed(dir, Path.join(sub, name), data, mode)
    :ok
  end

  @doc "Writes `host.md`, the description of your machine that `mwt host` also prints."
  @spec write_host(Path.t(), String.t()) :: :ok
  def write_host(dir, text), do: put_changed(dir, "host.md", text)

  @doc """
  The environment a command explicitly using token grants gets: `env`
  variables hold the placeholder, `file_env` variables the token file path.
  Never install this environment on the VM or in a general shell profile.
  """
  @spec env([Grant.t()]) :: [{String.t(), String.t()}]
  def env(grants) do
    for %Grant{kind: :token} = grant <- grants,
        pair <-
          Enum.map(grant.env, &{&1, grant.placeholder}) ++
            Enum.map(grant.file_env, &{&1, Grant.token_file(grant)}),
        do: pair
  end

  @doc """
  The VM's CA bundle: the roots this machine trusts, then the identity's CA.
  The guest's own bundle would do as well, but it isn't known until the image
  runs, and these are the same public roots.
  """
  @spec bundle(String.t()) :: String.t()
  def bundle(ca_pem) do
    roots =
      try do
        :public_key.cacerts_get()
        |> Enum.map(fn {:cert, der, _decoded} -> {:Certificate, der, :not_encrypted} end)
        |> :public_key.pem_encode()
      rescue
        _ -> ""
      end

    roots <> ca_pem
  end

  # What `mwt exec` needs to run a grant's presentation (`mwt-present`),
  # which it then runs with the command: placeholders only.
  defp present_script(%Grant{} = grant) do
    metadata =
      case grant.presents do
        %{metadata: %{project: project, email: email}} ->
          "export MWT_PRESENT=metadata\n" <>
            "export MWT_PRESENT_TOKEN=#{shell_word(grant.placeholder)}\n" <>
            "export MWT_PRESENT_PROJECT=#{shell_word(project)}\n" <>
            "export MWT_PRESENT_EMAIL=#{shell_word(email)}\n"

        _none ->
          ""
      end

    # Google's client libraries take a login file before a metadata
    # server: with both, the file is what they use.
    login =
      if Grant.login_placeholder(grant),
        do: "export GOOGLE_APPLICATION_CREDENTIALS=#{shell_word(Grant.login_file(grant))}\n",
        else: ""

    metadata <> login
  end

  @doc """
  A grant's Google login file (`Grant.login_file/1`): an `authorized_user`
  login whose refresh token is the grant's login placeholder, which MWT
  answers for at Google's token endpoint
  (`MWTClient.Sandbox.CredentialEndpoint`). The client id is gcloud's own,
  which is public; the secret is no secret, since nothing it signs leaves
  MWT.
  """
  @spec login_file(Grant.t()) :: String.t()
  def login_file(%Grant{} = grant) do
    Jason.encode!(
      %{
        type: "authorized_user",
        client_id: @gcloud_client_id,
        client_secret: "mwt-not-a-secret",
        refresh_token: Grant.login_placeholder(grant)
      },
      pretty: true
    ) <> "\n"
  end

  defp shell_word(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"

  # What `mwt exec` says for a grant only its subgrants use: there is
  # nothing to run with, and which subgrants to call instead.
  defp subgrants_only_script(grant, grants) do
    calls =
      case Grant.subgrants(grants, grant) do
        [] -> "It has none yet: ask the user to add one."
        subgrants -> "Call one of them: " <> Enum.map_join(subgrants, ", ", &"mwt call #{&1.id}")
      end

    "echo 'mwt: #{grant.id} is only for its subgrants, which MWT sends itself: the VM holds nothing of it. #{calls}' >&2\nreturn 125\n"
  end

  defp env_script(grants) do
    lines = for {var, value} <- env(grants), do: "export #{var}='#{value}'\n"

    "# Written by MWT. Placeholders only: MWT swaps in real values on the way out.\n" <>
      Enum.join(lines)
  end

  # Files that rarely change are left untouched when they haven't, so the VM
  # never sees them rewritten for nothing.
  defp put_changed(dir, name, data, mode \\ 0o644) do
    case File.read(Path.join(dir, name)) do
      {:ok, ^data} -> :ok
      _ -> put(dir, name, data, mode)
    end
  end

  # Written aside and renamed, so the VM never reads half a file.
  defp put(dir, name, data, mode \\ 0o644) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    partial = path <> ".part"
    File.write!(partial, data)
    File.chmod!(partial, mode)
    File.rename!(partial, path)
  end

  # The workspace's folder, the same path here and in the VM, quoted for
  # sh. Nothing while there is none.
  defp workspace(nil), do: ""

  defp workspace(root) do
    quoted = "'" <> String.replace(root, "'", ~S('\'')) <> "'"

    "\n# The workspace: what you leave in from-vm reaches the user's machine,\n" <>
      "# what their machine leaves in to-vm reaches you (mwt sync).\n" <>
      "export MWT_WORKSPACE=#{quoted}\n"
  end

  defp priv(name), do: File.read!(Path.join([:code.priv_dir(:mwt_client), "sandbox", name]))

  @doc "MWT's presentations (`native/mwt_present`), built beside msb, or nil."
  @spec presenter() :: Path.t() | nil
  def presenter do
    path = Path.join(MWTClient.Sandbox.Msb.runtime_dir(), "bin/mwt-present")
    if File.regular?(path), do: path
  end

  @doc "MWT's ACP shell (`native/mwt_acp`), built beside msb, or nil."
  @spec acp_shell() :: Path.t() | nil
  def acp_shell do
    path = Path.join(MWTClient.Sandbox.Msb.runtime_dir(), "bin/mwt-acp")
    if File.regular?(path), do: path
  end
end
