defmodule Mix.Tasks.Microsandbox.Update do
  @shortdoc "Moves the microsandbox pin to a release and reports what changed upstream"

  @moduledoc """
  Moves `scripts/microsandbox.pin` to an upstream release of microsandbox,
  and writes what changed between the two to
  `tmp/microsandbox-update-OLD-NEW.md`, to read before anything is built:

      mix microsandbox.update 0.8.2

  It builds and runs nothing of microsandbox's; it reads. From the release:
  its commit, by its tag, and the digests of the files MWT takes as they
  are (`agentd`, `libkrunfw`, for both architectures), from GitHub's
  release API. From that commit's source: the libkrun msb builds with
  (`Cargo.lock`), the kernel (`vendor/libkrunfw`) and the file name msb
  looks for it by. `scripts/build-microsandbox.sh` checks all of it again
  when it builds.

  The report says, in this order: what to look at first (a kernel that
  changed under the same file name, libkrun from a git commit, the store's
  migrations, breaking changes, security fixes, a call MWT's seccomp filter
  refuses); what the pin changes; the release's files added or gone;
  upstream's own notes for the releases in between; then, for each part of
  msb MWT depends on, the commits and files that touch it; and every
  commit.

  Upstream's history is kept in `tmp/microsandbox-upstream`, a partial
  clone that fetches a file only when the report reads it. An older
  release than the pin's is refused: going back is the pin's own history
  in git.

  Then: `./scripts/install-runtime.sh`, `mix test --only msb` (the flags,
  seconds), `mix test --only vm` (a real VM, minutes).
  """

  use Mix.Task

  alias MWTClient.Sandbox.Seccomp

  # The release files build-microsandbox.sh downloads, by the pin key that
  # holds each one's digest.
  @assets %{
    "AGENTD_SHA256_X86_64" => "agentd-x86_64",
    "AGENTD_SHA256_AARCH64" => "agentd-aarch64",
    "LIBKRUNFW_SHA256_X86_64" => "libkrunfw-linux-x86_64.so",
    "LIBKRUNFW_SHA256_AARCH64" => "libkrunfw-linux-aarch64.so"
  }

  # The parts of microsandbox MWT depends on: the upstream paths that make
  # each one, and what of MWT stands on it.
  @areas [
    {"Command line", ~w(crates/cli),
     "every flag MWT passes (`MWTClient.Sandbox.Msb.Commands`), checked by `mix test --only msb`"},
    {"Network, proxy and DNS", ~w(crates/network),
     "`--proxy` and `--dns-nameserver` send every connection and name to MWT; the bubble has no other way out"},
    {"Images and their cache", ~w(crates/image sdk/rust/lib/image),
     "`msb load`, `create --pull never`, `image inspect` (`Msb.image?/2`)"},
    {"The store and its migrations", ~w(crates/migration crates/db sdk/rust/lib/db),
     "each identity's microsandbox home: a store an msb migrated may not open under an older one"},
    {"The VM's process",
     ~w(crates/runtime sdk/rust/lib/runtime sdk/rust/lib/sandbox sdk/rust/lib/context),
     "`msb machine --name` (the relay, `Bubble`), `create --replace`, start, stop, live memory"},
    {"Guest agent", ~w(crates/agentd crates/protocol),
     "`exec`, `exec --stream` (git's `ext::`), `ssh serve` and its port forwards"},
    {"Filesystem", ~w(crates/filesystem), "the image's EROFS root and the `--mount-disk` disks"},
    {"Build and firmware",
     ~w(Cargo.toml justfile vendor crates/utils/lib/lib.rs .github/workflows),
     "`scripts/build-microsandbox.sh`: features, the embedded agent, release files, libkrunfw"}
  ]

  # The store's migrations: a change there may keep an older msb out of a
  # store the new one opened.
  @migrations "crates/migration"
  # The guest agent, which runs in the VM, where MWT's seccomp filter
  # doesn't apply: its calls aren't the bubble's.
  @guest "crates/agentd"

  # Commits listed under each part, before "and N more".
  @listed 25

  @impl Mix.Task
  def run(args) do
    new =
      case args do
        [version] -> version(version)
        _ -> Mix.raise("Usage: mix microsandbox.update VERSION (an upstream release, as 0.8.2)")
      end

    root = File.cwd!()
    pin_path = Path.join(root, "scripts/microsandbox.pin")
    text = File.read!(pin_path)
    old = parse_pin(text)

    if Version.compare(new, version(old["UPSTREAM"])) == :lt do
      Mix.raise(
        "#{new} is older than the pin's #{old["UPSTREAM"]}: go back through the pin's history " <>
          "(git log -- scripts/microsandbox.pin), with the kernel it had."
      )
    end

    repository = old["REPOSITORY"]
    upstream = Path.join(root, "tmp/microsandbox-upstream")
    tag = "v#{new}"
    Mix.shell().info("==> upstream history into #{Path.relative_to(upstream, root)}")
    fetch!(upstream, repository, old["REVISION"], tag)
    commit = upstream |> git!(["rev-parse", tag <> "^{commit}"]) |> String.trim()

    Mix.shell().info("==> release files of v#{old["UPSTREAM"]} and #{tag}")
    {:ok, _} = Application.ensure_all_started(:req)
    old_files = release_files!(repository, "v#{old["UPSTREAM"]}")
    new_files = release_files!(repository, tag)

    values =
      %{"UPSTREAM" => to_string(new), "REVISION" => commit}
      |> Map.merge(
        source_facts(
          git!(upstream, ["show", commit <> ":Cargo.lock"]),
          git!(upstream, ["show", commit <> ":crates/utils/lib/lib.rs"]),
          upstream |> git!(["rev-parse", commit <> ":vendor/libkrunfw"]) |> String.trim()
        )
      )
      |> Map.merge(digests!(new_files, tag))

    Mix.shell().info(
      "==> what changed, #{String.slice(old["REVISION"], 0, 9)}..#{String.slice(commit, 0, 9)}"
    )

    report =
      report(%{
        old: old,
        new: Map.merge(old, values),
        upstream: upstream,
        old_files: old_files,
        new_files: new_files,
        denied: seccomp_denied()
      })

    report_path = Path.join(root, "tmp/microsandbox-update-#{old["UPSTREAM"]}-#{new}.md")
    File.mkdir_p!(Path.dirname(report_path))
    File.write!(report_path, report)
    File.write!(pin_path, put_pin(text, values))

    Mix.shell().info("""
    ==> scripts/microsandbox.pin: #{old["UPSTREAM"]} -> #{new}
    ==> read #{Path.relative_to(report_path, root)}, then:
        ./scripts/install-runtime.sh
        mix test --only msb
        mix test --only vm
    """)
  end

  @doc "A release's version, with or without its tag's `v`."
  @spec version(String.t()) :: Version.t()
  def version(text) do
    case Version.parse(String.trim_leading(text, "v")) do
      {:ok, version} -> version
      :error -> Mix.raise("Not a release version: #{inspect(text)}")
    end
  end

  @doc "The pin's `KEY=VALUE` lines, by key; comments and blank lines are skipped."
  @spec parse_pin(String.t()) :: %{String.t() => String.t()}
  def parse_pin(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {key, value}
        _ -> Mix.raise("The pin has a line that isn't KEY=VALUE: #{line}")
      end
    end)
  end

  @doc """
  The pin's text with `values` in place of the ones it has, everything
  else as it was. A key the pin doesn't have is refused: the build script
  wouldn't read it.
  """
  @spec put_pin(String.t(), %{String.t() => String.t()}) :: String.t()
  def put_pin(text, values) do
    case Map.keys(values) -- Map.keys(parse_pin(text)) do
      [] -> :ok
      keys -> Mix.raise("The pin has no #{Enum.join(keys, ", ")}")
    end

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      case Regex.run(~r/\A([A-Z0-9_]+)=/, line) do
        [_, key] when is_map_key(values, key) -> "#{key}=#{Map.fetch!(values, key)}"
        _ -> line
      end
    end)
  end

  @doc """
  What a commit's source says the pin holds: from its `Cargo.lock`, the
  libkrun msb builds with; from `crates/utils/lib/lib.rs`, the kernel's
  file name msb looks for; and the `vendor/libkrunfw` commit.
  """
  @spec source_facts(String.t(), String.t(), String.t()) :: %{String.t() => String.t()}
  def source_facts(cargo_lock, utils, kernel) do
    block =
      cargo_lock
      |> String.split("[[package]]")
      |> Enum.find("", &String.contains?(&1, ~s(\nname = "msb_krun"\n)))

    field = fn name ->
      case Regex.run(~r/^#{name} = "([^"]+)"$/m, block) do
        [_, value] -> value
        nil -> Mix.raise("Cargo.lock has no #{name} for msb_krun")
      end
    end

    libkrunfw =
      case Regex.run(~r/LIBKRUNFW_VERSION: &str = "([^"]+)"/, utils) do
        [_, version] -> "libkrunfw.so." <> version
        nil -> Mix.raise("crates/utils/lib/lib.rs no longer says which libkrunfw msb looks for")
      end

    %{
      "LIBKRUN_VERSION" => field.("version"),
      "LIBKRUN_SOURCE" => field.("source"),
      "LIBKRUNFW" => libkrunfw,
      "KERNEL" => kernel
    }
  end

  @doc """
  The pin's digests from a release's files (name to `sha256:HEX`, as
  GitHub lists them). A file that isn't there is refused: the build
  downloads each one by its name.
  """
  @spec digests!(%{String.t() => String.t() | nil}, String.t()) :: %{String.t() => String.t()}
  def digests!(files, tag) do
    Map.new(@assets, fn {key, name} ->
      case Map.get(files, name) do
        "sha256:" <> hex when byte_size(hex) == 64 ->
          {key, hex}

        _ ->
          Mix.raise(
            "#{tag} has no #{name} with a sha256 digest: build-microsandbox.sh downloads it by that name"
          )
      end
    end)
  end

  @doc """
  The commits of `git log --format=%h%x1f%s%x1f%b%x1e`, each with its kind:
  `:breaking` (a `!` before the colon, or a `BREAKING CHANGE`), `:security`
  (GitHub's "Merge commit from fork", how a security advisory's fix lands,
  told by its first line), or its Conventional Commit type.
  """
  @spec commits(String.t()) :: [
          %{hash: String.t(), subject: String.t(), kind: atom() | String.t()}
        ]
  def commits(log) do
    log
    |> String.split("\x1e", trim: true)
    |> Enum.map(&String.trim_leading(&1, "\n"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn entry ->
      [hash, subject, body] =
        case String.split(entry, "\x1f", parts: 3) do
          [hash, subject, body] -> [hash, subject, body]
          [hash, subject] -> [hash, subject, ""]
        end

      cond do
        subject == "Merge commit from fork" ->
          %{hash: hash, subject: "security fix: " <> first_line(body), kind: :security}

        subject =~ ~r/\A\w+(\([^)]*\))?!:/ or body =~ "BREAKING CHANGE" ->
          %{hash: hash, subject: subject, kind: :breaking}

        true ->
          kind =
            case Regex.run(~r/\A(\w+)(\([^)]*\))?:/, subject) do
              [_, type | _] -> type
              nil -> "other"
            end

          %{hash: hash, subject: subject, kind: kind}
      end
    end)
  end

  defp first_line(body) do
    body
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("* ")))
    |> Enum.find("(no description)", &(&1 != ""))
  end

  @doc """
  Lines a diff adds that make a call MWT's seccomp filter refuses
  (`denied`), through `libc`, `nix` or `rustix`, or by its `SYS_` number,
  as `{file, line}`. Such a call in msb would fail with EPERM in the
  bubble.
  """
  @spec denied_calls(String.t(), [atom()]) :: [{String.t(), String.t()}]
  def denied_calls(diff, denied) do
    names = Enum.map_join(denied, "|", &Regex.escape(Atom.to_string(&1)))

    pattern =
      ~r/\b(?:libc|nix|rustix)::(?:\w+::)*(?:SYS_)?(?:#{names})\b|\bSYS_(?:#{names})\b/

    diff
    |> String.split("\n")
    |> Enum.reduce({nil, []}, fn
      "+++ b/" <> file, {_file, hits} ->
        {file, hits}

      "+++" <> _, {_file, hits} ->
        {nil, hits}

      "+" <> line, {file, hits} when is_binary(file) ->
        if line =~ pattern, do: {file, [{file, String.trim(line)} | hits]}, else: {file, hits}

      _line, acc ->
        acc
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc """
  Upstream's notes worth reading for a move from `old` to `new`, among the
  files of its `docs/changelog` and `docs/migrations`: the changelog of
  every release after `old` up to `new`, and the migration guide of every
  minor version crossed.
  """
  @spec notes([String.t()], Version.t(), Version.t()) :: [String.t()]
  def notes(paths, old, new) do
    Enum.filter(paths, fn path ->
      case Regex.run(~r{\Adocs/(changelog|migrations)/v(\d+)\.(\d+)(?:\.(\d+))?\.mdx\z}, path) do
        [_, "changelog", major, minor, patch] ->
          version = Version.parse!("#{major}.#{minor}.#{patch}")
          Version.compare(version, old) == :gt and Version.compare(version, new) != :gt

        [_, "migrations", major, minor] ->
          series = {String.to_integer(major), String.to_integer(minor)}
          series > {old.major, old.minor} and series <= {new.major, new.minor}

        _ ->
          false
      end
    end)
  end

  @doc """
  What to look at first, from the old pin, the new one, the commits, the
  files of the store's migrations that changed, and the denied calls the
  new source makes.
  """
  @spec first_looks(map(), map(), [map()], [String.t()], [tuple()]) :: [String.t()]
  def first_looks(old, new, commits, migrations, denied) do
    breaking = Enum.count(commits, &(&1.kind == :breaking))
    security = Enum.count(commits, &(&1.kind == :security))

    [
      (new["KERNEL"] != old["KERNEL"] and new["LIBKRUNFW"] == old["LIBKRUNFW"]) &&
        "**The kernel changed under the same file name** (`#{new["LIBKRUNFW"]}`): an msb and a kernel " <>
          "of different releases can't be told apart by their files, so `bin/` and `lib/` move together, rollback included.",
      new["LIBKRUNFW"] != old["LIBKRUNFW"] &&
        "**msb looks for another kernel file:** `#{old["LIBKRUNFW"]}` -> `#{new["LIBKRUNFW"]}`.",
      new["LIBKRUN_SOURCE"] != old["LIBKRUN_SOURCE"] &&
        "**libkrun comes from elsewhere:** `#{old["LIBKRUN_SOURCE"]}` -> `#{new["LIBKRUN_SOURCE"]}`" <>
          if(String.starts_with?(new["LIBKRUN_SOURCE"], "git+"),
            do:
              ": a git commit, which the build fetches from there, and which this report doesn't read.",
            else: "."
          ),
      migrations != [] &&
        "**The store's migrations changed** (#{Enum.map_join(migrations, ", ", &"`#{&1}`")}): " <>
          "once the new msb opens an identity's store, an older one may not.",
      breaking > 0 && "**#{breaking} breaking change#{if breaking > 1, do: "s"}** (listed below).",
      security > 0 &&
        "**#{security} security fix#{if security > 1, do: "es"}** (GitHub advisories, listed below): " <>
          "see whether each reaches MWT, whose bubble and proxy stand in front of msb.",
      denied != [] &&
        "**#{length(denied)} added line#{if length(denied) > 1, do: "s make", else: " makes"} a call MWT's seccomp filter refuses** " <>
          "(listed below): msb would get EPERM there."
    ]
    |> Enum.filter(&is_binary/1)
  end

  # Fetches the old pin's commit by its hash and the new release's tag, with
  # trees but no file contents, which come as the report reads them.
  defp fetch!(dir, repository, revision, tag) do
    unless File.dir?(Path.join(dir, ".git")) do
      File.mkdir_p!(dir)
      git!(dir, ["init", "--quiet"])
    end

    git!(dir, [
      "fetch",
      "--quiet",
      "--filter=blob:none",
      repository,
      revision,
      "+refs/tags/#{tag}:refs/tags/#{tag}"
    ])
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args]) do
      {output, 0} -> output
      {output, status} -> Mix.raise("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  # A release's files, by name, with GitHub's digest of each.
  defp release_files!(repository, tag) do
    url = "https://api.github.com/repos/#{github_path(repository)}/releases/tags/#{tag}"

    case Req.get(url, headers: [{"accept", "application/vnd.github+json"}], retry: :transient) do
      {:ok, %{status: 200, body: %{"assets" => assets}}} ->
        Map.new(assets, &{&1["name"], &1["digest"]})

      {:ok, %{status: status}} ->
        Mix.raise("GitHub answered #{status} for #{url}")

      {:error, error} ->
        Mix.raise("Couldn't reach #{url}: #{Exception.message(error)}")
    end
  end

  defp github_path(repository) do
    case Regex.run(~r{\Ahttps://github\.com/([^/]+/[^/]+?)(?:\.git)?\z}, repository) do
      [_, path] -> path
      nil -> Mix.raise("The pin's REPOSITORY isn't on GitHub: #{repository}")
    end
  end

  defp seccomp_denied do
    [:x86_64, :aarch64] |> Enum.flat_map(&Seccomp.denied/1) |> Enum.uniq()
  end

  defp report(%{old: old, new: new, upstream: dir} = facts) do
    range = "#{old["REVISION"]}..#{new["REVISION"]}"
    web = String.trim_trailing(old["REPOSITORY"], ".git")
    link = fn hash -> "[`#{String.slice(hash, 0, 8)}`](#{web}/commit/#{hash})" end
    line = fn commit -> "- #{link.(commit.hash)} #{commit.subject}" end

    commits = commits(git!(dir, ["log", "--format=%H%x1f%s%x1f%b%x1e", range]))

    areas =
      Enum.map(@areas, fn {name, paths, why} ->
        touched = commits(git!(dir, ["log", "--format=%H%x1f%s%x1f%b%x1e", range, "--" | paths]))

        stat =
          dir
          |> git!(["diff", "--shortstat", old["REVISION"], new["REVISION"], "--" | paths])
          |> String.trim()

        %{name: name, paths: paths, why: why, commits: touched, stat: stat}
      end)

    migrations =
      dir
      |> git!(["diff", "--name-only", old["REVISION"], new["REVISION"], "--", @migrations])
      |> String.split("\n", trim: true)

    rust_diff =
      git!(dir, [
        "diff",
        "--unified=0",
        old["REVISION"],
        new["REVISION"],
        "--",
        "*.rs",
        ":(exclude)**/tests/**",
        ":(exclude)**/*test*.rs",
        ":(exclude)#{@guest}/**"
      ])

    denied = denied_calls(rust_diff, facts.denied)

    notes =
      dir
      |> git!([
        "ls-tree",
        "-r",
        "--name-only",
        new["REVISION"],
        "--",
        "docs/changelog",
        "docs/migrations"
      ])
      |> String.split("\n", trim: true)
      |> notes(version(old["UPSTREAM"]), version(new["UPSTREAM"]))

    compatibility =
      case System.cmd("git", [
             "-C",
             dir,
             "diff",
             "--quiet",
             old["REVISION"],
             new["REVISION"],
             "--",
             "COMPATIBILITY.md"
           ]) do
        {_, 1} -> ["COMPATIBILITY.md"]
        _ -> []
      end

    linux = fn files -> files |> Map.keys() |> Enum.filter(&(&1 =~ ~r/linux|agentd/)) end
    added = linux.(facts.new_files) -- linux.(facts.old_files)
    gone = linux.(facts.old_files) -- linux.(facts.new_files)

    by_kind = Enum.group_by(commits, & &1.kind)
    kinds = [:breaking, :security, "feat", "fix", "perf", "refactor"]
    rest = commits |> Enum.reject(&(&1.kind in kinds))

    list = fn
      [], none -> none
      items, _none -> Enum.join(items, "\n")
    end

    pin_rows =
      for key <- ~w(UPSTREAM REVISION LIBKRUN_VERSION LIBKRUN_SOURCE LIBKRUNFW KERNEL),
          do:
            "| `#{key}` | `#{old[key]}` | `#{new[key]}`#{if old[key] == new[key], do: " (same)", else: ""} |"

    sections = [
      "# microsandbox #{old["UPSTREAM"]} -> #{new["UPSTREAM"]}",
      "#{length(commits)} upstream commits, #{link.(old["REVISION"])}..#{link.(new["REVISION"])}. " <>
        "Written by `mix microsandbox.update`; nothing of it was built or run.",
      "## Look at first",
      list.(
        Enum.map(first_looks(old, new, commits, migrations, denied), &("- " <> &1)),
        "Nothing stands out."
      ),
      "## Next",
      "1. `./scripts/install-runtime.sh` (or `./scripts/build-microsandbox.sh`): builds it, checking the pin again.\n" <>
        "2. `mix test --only msb`: every flag MWT passes, the answers MWT reads. Seconds, no VM.\n" <>
        "3. `mix test --only vm`: a real VM, confined, its network and disks. Minutes, needs `/dev/kvm`.\n" <>
        "4. A VM made by the old msb: start it under the new one, and recreate it.",
      "## The pin",
      "| | #{old["UPSTREAM"]} | #{new["UPSTREAM"]} |\n|---|---|---|\n" <>
        Enum.join(pin_rows, "\n"),
      "## Release files (Linux)",
      list.(
        Enum.map(added, &"- new: `#{&1}`") ++ Enum.map(gone, &"- gone: `#{&1}`"),
        "The same files."
      ),
      "## Upstream's notes",
      list.(
        Enum.map(notes ++ compatibility, &"- [#{&1}](#{web}/blob/v#{new["UPSTREAM"]}/#{&1})"),
        "None."
      ),
      "## Calls MWT's seccomp filter refuses",
      "Added lines of msb's own source (tests left out) that call one through `libc`, `nix` or `rustix`. " <>
        "Left out: the guest agent (`#{@guest}`), which runs in the VM, where the filter doesn't apply; " <>
        "libkrun, a dependency, which isn't read here.",
      list.(
        Enum.map(Enum.take(denied, 40), fn {file, text} -> "- `#{file}`: `#{text}`" end),
        "None."
      ),
      "## The parts MWT depends on"
    ]

    area_sections =
      Enum.flat_map(areas, fn area ->
        listed = Enum.take(area.commits, @listed)
        more = length(area.commits) - length(listed)

        [
          "### #{area.name}",
          "What MWT counts on: #{area.why}. Upstream: #{Enum.map_join(area.paths, ", ", &"`#{&1}`")}; " <>
            if(area.stat == "", do: "unchanged.", else: "#{area.stat}."),
          list.(
            Enum.map(listed, line) ++ if(more > 0, do: ["- and #{more} more"], else: []),
            "No commits."
          )
        ]
      end)

    commit_sections =
      ["## Every commit"] ++
        Enum.flat_map(kinds, fn kind ->
          case Map.get(by_kind, kind, []) do
            [] -> []
            some -> ["### #{kind}", some |> Enum.map(line) |> Enum.join("\n")]
          end
        end) ++
        if(rest == [], do: [], else: ["### the rest", rest |> Enum.map(line) |> Enum.join("\n")])

    (sections ++ area_sections ++ commit_sections)
    |> List.flatten()
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end
end
