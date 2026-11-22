defmodule MWTClient.Updates do
  @moduledoc """
  Updates MWT from its public releases, or from a package you downloaded
  and picked: the `.deb` where MWT was installed from its Debian package,
  the `.rpm` where it came from its Fedora one.

  From the releases: MWT asks GitHub for the latest release of
  `oliveigah/my_work_tools` when you check, a minute after it starts and
  once a day after that. Those quiet checks speak up only when there is a
  newer MWT, and not again for one you dismissed. Installing it downloads
  the release's `SHA256SUMS`, its Ed25519 signature `SHA256SUMS.sig` and
  the package into a folder only you can open. The signature has to verify
  with the release key MWT ships (`priv/release_signing_key.pub`), and the
  package has to match its line in the sums: a release whose checksums
  that key didn't sign is never installed, and an MWT without the key
  checks no release at all.

  From a file: the picked file is copied into a folder only you can open,
  and the copy is what MWT reads and the system installer installs: what
  you confirm is what was checked, and root can read it even when the
  original sits where it can't (a portal or network mount).

  Either way the package has to be the `mwt` package, newer than the MWT
  running, and pkexec installs it. Checking, downloading, copying and
  installing run outside the GenServer so the interface stays responsive.
  """

  use GenServer

  require Logger

  alias MWTClient.Sandbox.Scratch

  @topic "mwt:updates"

  @repository "oliveigah/my_work_tools"
  @latest_url "https://api.github.com/repos/#{@repository}/releases/latest"
  @request_options [
    headers: [{"user-agent", "MWT updater"}, {"accept", "application/vnd.github+json"}],
    receive_timeout: 30_000,
    retry: false
  ]

  @first_check :timer.minutes(1)
  @check_every :timer.hours(24)

  # Far above any MWT package: a wrong pick doesn't fill the temporary folder.
  @max_package_bytes 2 * 1024 * 1024 * 1024

  @busy [:checking, :downloading, :reading, :installing]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(MWTClient.PubSub, @topic)
  def current, do: GenServer.call(__MODULE__, :current)

  @doc """
  Asks for the latest release now; the update notice says what came of it,
  a newer MWT to install or that this one is the latest.
  """
  def check, do: GenServer.call(__MODULE__, :check)

  @doc """
  The package the picker offers: `{:ok, "deb"}` or `{:ok, "rpm"}`, as MWT was
  installed. Where MWT can't update itself, `{:error, reason}`, which the
  update notice shows too.
  """
  def picker, do: GenServer.call(__MODULE__, :picker)

  @doc "Reads the package at `path`, the file you picked, after `picker/0`."
  def select(path), do: GenServer.call(__MODULE__, {:select, path})

  @doc "Shows in the update notice why the picker didn't open."
  def picker_failed(reason), do: GenServer.call(__MODULE__, {:picker_failed, reason})

  @doc """
  Installs the newer release found (downloading and verifying it first), or
  the package picked, once read.
  """
  def install, do: GenServer.call(__MODULE__, :install)

  def dismiss, do: GenServer.call(__MODULE__, :dismiss)

  @doc """
  The latest release, as GitHub describes it, against the MWT running:
  `{:ok, release}` when it is newer and carries the `format` package, the
  sums and their signature; `:current` when it isn't newer; otherwise
  `{:error, reason}` to show.
  """
  def select_release(%{"tag_name" => tag, "assets" => assets}, current_version, format)
      when is_list(assets) and format in [:deb, :rpm] do
    with {:ok, version} <- parse_version(tag),
         {:ok, running} <- parse_version(current_version) do
      if version > running do
        release_assets(tag, version_string(version), assets, format)
      else
        :current
      end
    else
      :error -> {:error, "Could not read the version of the latest release: #{tag}."}
    end
  end

  def select_release(_release, _current_version, _format),
    do: {:error, "Could not read the latest release."}

  defp release_assets(tag, version, assets, format) do
    name = "MWT_#{version}.#{format}"

    urls =
      for asset <- [name, "SHA256SUMS", "SHA256SUMS.sig"] do
        case Enum.find(assets, &(&1["name"] == asset)) do
          %{"browser_download_url" => url} -> if release_url?(url, tag, asset), do: url
          _ -> nil
        end
      end

    case urls do
      [package_url, sums_url, signature_url]
      when is_binary(package_url) and is_binary(sums_url) and is_binary(signature_url) ->
        {:ok,
         %{
           version: version,
           name: name,
           package_url: package_url,
           sums_url: sums_url,
           signature_url: signature_url,
           format: format
         }}

      _ ->
        {:error, "MWT #{version} is out, but its release has no signed .#{format} package yet."}
    end
  end

  defp release_url?(url, tag, name) when is_binary(url) do
    url == "https://github.com/#{@repository}/releases/download/#{URI.encode(tag)}/#{name}"
  end

  defp release_url?(_url, _tag, _name), do: false

  @doc "Finds the exact SHA-256 line for `name` in a release's `SHA256SUMS`."
  def checksum(sums, name) do
    sums
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ~r/\s+/, parts: 2, trim: true) do
        [hash, file] ->
          if String.trim_leading(file, "./") == name and
               String.match?(hash, ~r/\A[0-9a-fA-F]{64}\z/),
             do: {:ok, String.downcase(hash)}

        _ ->
          nil
      end
    end)
  end

  @doc """
  Whether `signature` is the Ed25519 signature of `sums` by the release key
  `key` (its 32 bytes, see `decode_key/1`).
  """
  def signed?(sums, signature, key)
      when is_binary(sums) and byte_size(signature) == 64 and byte_size(key) == 32 do
    :crypto.verify(:eddsa, :none, sums, signature, [key, :ed25519])
  end

  def signed?(_sums, _signature, _key), do: false

  @doc """
  The release key's 32 bytes from its PEM (`-----BEGIN PUBLIC KEY-----`, as
  `openssl pkey -pubout` writes it): `{:ok, key}`, or `:error` for anything
  but one Ed25519 public key.
  """
  def decode_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:SubjectPublicKeyInfo, _der, :not_encrypted} = entry] ->
        case :public_key.pem_entry_decode(entry) do
          {{:ECPoint, <<key::binary-size(32)>>}, {:namedCurve, {1, 3, 101, 112}}} -> {:ok, key}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  def decode_key(_pem), do: :error

  @doc "The key MWT's releases are signed with, from `priv/release_signing_key.pub`."
  def release_key do
    with {:ok, pem} <- File.read(Application.app_dir(:mwt_client, "priv/release_signing_key.pub")),
         {:ok, key} <- decode_key(pem) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  @doc """
  Asks GitHub for the latest release and weighs it with `select_release/3`.
  `options` go to Req after MWT's own.
  """
  def latest_release(format, current_version, options \\ []) do
    case Req.get(@latest_url, Keyword.merge(@request_options, options)) do
      {:ok, %Req.Response{status: 200, body: %{} = release}} ->
        select_release(release, current_version, format)

      {:ok, %Req.Response{status: 404}} ->
        {:error, "No MWT release is published yet."}

      other ->
        Logger.info("MWT release check unavailable: #{inspect(other, limit: 5)}")
        {:error, "Could not check for updates. Please try again."}
    end
  end

  @doc """
  Downloads `release` into a folder only you can open and checks it: the
  sums signed by `key`, the package matching its sum, and the package
  being MWT at the release's version, newer than `current_version`.
  `{:ok, package}` as `read_package/3` gives one, or `{:error, reason}`,
  and then nothing stays.
  """
  def download_release(release, current_version, key, options \\ []) do
    dir = Scratch.dir!("mwt-update")
    path = Path.join(dir, release.name)
    options = Keyword.merge(@request_options, [decode_body: false] ++ options)

    result =
      with {:ok, sums} <- fetch(release.sums_url, options),
           {:ok, signature} <- fetch(release.signature_url, options),
           true <- signed?(sums, signature, key) || {:error, :unsigned},
           {:ok, expected} <- checksum(sums, release.name) |> or_error(:no_sum),
           {:ok, _bytes} <- fetch_into(release.package_url, path, options),
           true <- sha256(path) == expected || {:error, :mismatch},
           {:ok, version} <- read_copy(release.format, path, current_version) do
        if version == release.version,
          do:
            {:ok,
             %{version: version, file: release.name, path: path, dir: dir, format: release.format}},
          else: {:error, :wrong_version}
      end

    case result do
      {:ok, _package} = ok ->
        ok

      {:error, reason} ->
        File.rm_rf(dir)
        {:error, download_error(reason, release)}
    end
  end

  defp fetch(url, options) do
    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      other -> {:error, {:download, other}}
    end
  end

  defp fetch_into(url, path, options) do
    options = Keyword.merge(options, into: File.stream!(path), receive_timeout: 300_000)

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200}} -> {:ok, File.stat!(path).size}
      other -> {:error, {:download, other}}
    end
  end

  defp or_error({:ok, _} = ok, _reason), do: ok
  defp or_error(:error, reason), do: {:error, reason}

  defp download_error(:unsigned, _release),
    do: "The release's checksums aren't signed with MWT's release key, so it wasn't installed."

  defp download_error(:no_sum, release), do: "The release's checksums don't list #{release.name}."

  defp download_error(:mismatch, _release),
    do: "The downloaded package doesn't match its release checksum, so it wasn't installed."

  defp download_error(:wrong_version, release),
    do: "The downloaded package isn't MWT #{release.version}, so it wasn't installed."

  defp download_error({:download, other}, _release) do
    Logger.info("MWT update download failed: #{inspect(other, limit: 5)}")
    "The update could not be downloaded. Please try again."
  end

  defp download_error(message, _release) when is_binary(message), do: message

  @doc """
  Copies the `format` package at `path` into a folder of its own and reads
  it: `{:ok, package}` when it is MWT, newer than `current_version`, with
  `package.path` the copy to install and `package.dir` its folder;
  otherwise `{:error, reason}`, and no copy stays.
  """
  def read_package(path, format, current_version) when format in [:deb, :rpm] do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_package_bytes ->
        copy_and_read(path, format, current_version)

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "This file is far larger than an MWT package."}

      {:ok, %File.Stat{}} ->
        {:error, "Choose a package file."}

      {:error, reason} ->
        {:error, "Could not open the file: #{:file.format_error(reason)}."}
    end
  end

  @doc """
  Whether the package `name` at `version` updates MWT from `current_version`:
  `{:ok, version}`, or `{:error, reason}` to show.
  """
  def verdict("mwt", version, current_version) do
    with {:ok, package} <- parse_version(version),
         {:ok, running} <- parse_version(current_version) do
      cond do
        package > running ->
          {:ok, version_string(package)}

        package == running ->
          {:error, "This package is MWT #{version}, the version you have."}

        true ->
          {:error, "This package is MWT #{version}, older than the #{current_version} you have."}
      end
    else
      :error -> {:error, "Could not read the version of this package: #{version}."}
    end
  end

  def verdict(name, _version, _current_version),
    do: {:error, "This is the package #{name}, not MWT."}

  @doc """
  The package's name and version, from `Package:` and `Version:` lines: how
  `dpkg-deb --field` prints them, and the format MWT asks `rpm` for.
  """
  def package_fields(output) do
    fields =
      for line <- String.split(output, "\n"),
          [key, value] <- [String.split(line, ":", parts: 2)],
          into: %{},
          do: {String.trim(key), String.trim(value)}

    case fields do
      %{"Package" => name, "Version" => version} -> {:ok, name, version}
      _ -> :error
    end
  end

  @impl true
  def init(_) do
    if desktop?(), do: Process.send_after(self(), :quiet_check, @first_check)

    {:ok,
     %{
       status: :idle,
       release: nil,
       package: nil,
       message: nil,
       task: nil,
       quiet: false,
       dismissed: nil,
       format: nil
     }}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, public_state(state), state}

  # A quiet check already under way becomes the one asked for.
  def handle_call(:check, _from, %{status: :idle, task: ref, quiet: true} = state)
      when is_reference(ref) do
    {:reply, :ok, publish(%{state | status: :checking, quiet: false, message: nil})}
  end

  def handle_call(:check, _from, %{status: status} = state) when status in @busy,
    do: {:reply, {:error, :busy}, state}

  def handle_call(:check, _from, state) do
    state = state |> drop_package() |> with_format()

    case checkable(state) do
      {:ok, format} ->
        state = start_check(state, format, false)
        {:reply, :ok, publish(%{state | status: :checking, release: nil, message: nil})}

      {:error, message} ->
        {:reply, {:error, :unavailable}, show_error(state, message)}
    end
  end

  def handle_call(:picker, _from, %{status: status} = state) when status in @busy,
    do: {:reply, {:error, :busy}, state}

  def handle_call({:select, _path}, _from, %{status: status} = state) when status in @busy,
    do: {:reply, {:error, :busy}, state}

  def handle_call(:picker, _from, state) do
    state = with_format(state)

    case state.format do
      {:ok, format} -> {:reply, {:ok, Atom.to_string(format)}, state}
      {:error, message} -> {:reply, {:error, message}, show_error(state, message)}
    end
  end

  def handle_call({:select, path}, _from, %{format: {:ok, format}} = state)
      when is_binary(path) do
    if Path.type(path) == :absolute do
      state = state |> drop_quiet_check() |> drop_package()
      current = current_version()

      task =
        Task.Supervisor.async_nolink(MWTClient.HttpClient.TaskSupervisor, fn ->
          {:read, read_package(path, format, current)}
        end)

      {:reply, :ok,
       publish(%{state | status: :reading, release: nil, message: nil, task: task.ref})}
    else
      {:reply, {:error, :relative},
       show_error(state, "The picker gave a relative path. Please choose the file again.")}
    end
  end

  def handle_call({:select, _path}, _from, state), do: {:reply, {:error, :no_picker}, state}

  def handle_call({:picker_failed, reason}, _from, %{status: status} = state)
      when status not in @busy and is_binary(reason) do
    {:reply, :ok, show_error(state, String.slice(reason, 0, 300))}
  end

  def handle_call({:picker_failed, _reason}, _from, state), do: {:reply, :ok, state}

  def handle_call(:install, _from, %{status: :available, release: release} = state) do
    case release_key() do
      {:ok, key} ->
        current = current_version()

        task =
          Task.Supervisor.async_nolink(MWTClient.HttpClient.TaskSupervisor, fn ->
            {:download, download_release(release, current, key)}
          end)

        {:reply, :ok, publish(%{state | status: :downloading, message: nil, task: task.ref})}

      :error ->
        {:reply, {:error, :unavailable}, show_error(state, no_key_message())}
    end
  end

  def handle_call(:install, _from, %{status: :ready} = state) do
    {:reply, :ok, start_install(state)}
  end

  def handle_call(:install, _from, state), do: {:reply, {:error, :unavailable}, state}

  def handle_call(:dismiss, _from, %{status: :available, release: release} = state) do
    {:reply, :ok,
     publish(%{state | status: :idle, release: nil, message: nil, dismissed: release.version})}
  end

  def handle_call(:dismiss, _from, %{status: status} = state)
      when status in [:ready, :current, :error] do
    state = drop_package(state)
    {:reply, :ok, publish(%{state | status: :idle, release: nil, message: nil})}
  end

  def handle_call(:dismiss, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(:quiet_check, state) do
    Process.send_after(self(), :quiet_check, @check_every)
    state = with_format(state)

    with %{status: :idle, task: nil} <- state,
         {:ok, format} <- checkable(state) do
      {:noreply, start_check(state, format, true)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({ref, {:check, result}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, checked(%{state | task: nil}, result)}
  end

  def handle_info({ref, {:download, {:ok, package}}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, start_install(%{state | package: package, task: nil})}
  end

  def handle_info({ref, {:download, {:error, message}}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, show_error(%{state | task: nil}, message)}
  end

  def handle_info({ref, {:read, {:ok, package}}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, publish(%{state | status: :ready, package: package, task: nil})}
  end

  def handle_info({ref, {:read, {:error, message}}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, show_error(%{state | task: nil}, message)}
  end

  def handle_info({ref, {:install, :ok}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, publish(%{drop_package(state) | status: :installed, release: nil, task: nil})}
  end

  def handle_info({ref, {:install, {:error, message}}}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, publish(%{state | status: :ready, message: message, task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
    Logger.warning("MWT update task stopped: #{inspect(reason)}")
    state = %{state | task: nil}

    case state.status do
      :installing ->
        message = "The update could not be installed. Please try again."
        {:noreply, publish(%{state | status: :ready, message: message})}

      :idle ->
        {:noreply, %{state | quiet: false}}

      :checking ->
        {:noreply, show_error(state, "Could not check for updates. Please try again.")}

      :downloading ->
        {:noreply, show_error(state, "The update could not be downloaded. Please try again.")}

      _reading ->
        {:noreply, show_error(state, "Could not read the package. Please try again.")}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Checking needs an installed package and the release key to verify what
  # it would install.
  defp checkable(%{format: {:ok, format}}) do
    case release_key() do
      {:ok, _key} -> {:ok, format}
      :error -> {:error, no_key_message()}
    end
  end

  defp checkable(%{format: {:error, message}}), do: {:error, message}

  defp no_key_message do
    "This MWT was built without its release key, so it doesn't check its releases. " <>
      "You can still install a package you downloaded."
  end

  defp start_check(state, format, quiet) do
    current = current_version()

    task =
      Task.Supervisor.async_nolink(MWTClient.HttpClient.TaskSupervisor, fn ->
        {:check, latest_release(format, current)}
      end)

    %{state | task: task.ref, quiet: quiet}
  end

  # A quiet check speaks up only for a newer MWT not dismissed already.
  defp checked(%{quiet: true} = state, {:ok, release}) do
    if release.version == state.dismissed,
      do: %{state | quiet: false},
      else: publish(%{state | quiet: false, status: :available, release: release, message: nil})
  end

  defp checked(%{quiet: true} = state, other) do
    if other != :current, do: Logger.info("MWT quiet update check: #{inspect(other)}")
    %{state | quiet: false}
  end

  defp checked(state, {:ok, release}),
    do: publish(%{state | status: :available, release: release, message: nil})

  defp checked(state, :current) do
    message = "MWT #{current_version()} is the latest."
    publish(%{state | status: :current, message: message})
  end

  defp checked(state, {:error, message}), do: show_error(state, message)

  defp drop_quiet_check(%{quiet: true, task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | task: nil, quiet: false}
  end

  defp drop_quiet_check(state), do: state

  defp start_install(%{package: package} = state) do
    task =
      Task.Supervisor.async_nolink(MWTClient.HttpClient.TaskSupervisor, fn ->
        {:install, install_package(package.format, package.path)}
      end)

    publish(%{state | status: :installing, message: nil, task: task.ref})
  end

  defp copy_and_read(path, format, current_version) do
    dir = Scratch.dir!("mwt-update")
    copy = Path.join(dir, "MWT.#{format}")

    result =
      case File.copy(path, copy) do
        {:ok, _bytes} -> read_copy(format, copy, current_version)
        {:error, reason} -> {:error, "Could not copy the file: #{:file.format_error(reason)}."}
      end

    case result do
      {:ok, version} ->
        {:ok,
         %{version: version, file: Path.basename(path), path: copy, dir: dir, format: format}}

      {:error, _message} = error ->
        File.rm_rf(dir)
        error
    end
  end

  defp read_copy(format, copy, current_version) do
    case package_info(format, copy) do
      {:ok, name, version} -> verdict(name, version, current_version)
      :error -> {:error, "This file is not a .#{format} package."}
    end
  end

  defp package_info(:deb, path),
    do: read_fields("dpkg-deb", ["--field", path, "Package", "Version"])

  defp package_info(:rpm, path) do
    read_fields("rpm", [
      "--query",
      "--package",
      "--nosignature",
      "--queryformat",
      "Package: %{NAME}\nVersion: %{VERSION}\n",
      path
    ])
  end

  defp read_fields(command, args) do
    with executable when is_binary(executable) <- MWTClient.Executable.find(command),
         {output, 0} <- System.cmd(executable, args, stderr_to_stdout: true) do
      package_fields(output)
    else
      _ -> :error
    end
  end

  defp install_package(format, path) do
    manager = if format == :deb, do: "apt-get", else: "dnf"

    with executable when is_binary(executable) <- MWTClient.Executable.find(manager),
         pkexec when is_binary(pkexec) <- MWTClient.Executable.find("pkexec"),
         {_output, 0} <-
           System.cmd(pkexec, [executable, "install", "-y", path], stderr_to_stdout: true) do
      :ok
    else
      nil ->
        {:error, "The system package installer is unavailable."}

      {output, _exit_code} ->
        Logger.warning("MWT package install failed: #{String.slice(output, -2000, 2000)}")

        {:error,
         "The system did not install the update. Check the authentication prompt and try again."}
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp show_error(state, message) do
    publish(%{drop_package(state) | status: :error, release: nil, message: message})
  end

  defp drop_package(%{package: nil} = state), do: state

  defp drop_package(%{package: package} = state) do
    File.rm_rf(package.dir)
    %{state | package: nil}
  end

  defp parse_version(version) when is_binary(version) do
    case Regex.run(~r/\Av?(\d+)\.(\d+)\.(\d+)\z/, version) do
      [_, major, minor, patch] ->
        {:ok, {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}}

      _ ->
        :error
    end
  end

  defp parse_version(_), do: :error
  defp version_string({major, minor, patch}), do: "#{major}.#{minor}.#{patch}"
  defp current_version, do: :mwt_client |> Application.spec(:vsn) |> to_string()

  defp desktop?, do: System.get_env("MWT_DESKTOP_BUILD") == "true"

  defp with_format(%{format: nil} = state), do: %{state | format: installed_format()}
  defp with_format(state), do: state

  defp installed_format do
    cond do
      not desktop?() ->
        {:error, "MWT updates itself only in the installed desktop app."}

      format = package_format() ->
        {:ok, format}

      true ->
        {:error, "Updates need MWT installed from its x86-64 Debian or Fedora package."}
    end
  end

  defp package_format do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      not String.starts_with?(arch, "x86_64") -> nil
      installed?("dpkg-query", ["-W", "-f=${Status}", "mwt"], "install ok installed") -> :deb
      installed?("rpm", ["-q", "mwt"], nil) -> :rpm
      true -> nil
    end
  end

  defp installed?(command, args, expected) do
    case MWTClient.Executable.find(command) do
      nil ->
        false

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: true) do
          {output, 0} -> expected == nil or String.trim(output) == expected
          _ -> false
        end
    end
  end

  defp public_state(state) do
    package = state.package && Map.take(state.package, [:version, :file])
    release = state.release && Map.take(state.release, [:version])
    %{status: state.status, package: package, release: release, message: state.message}
  end

  defp publish(state) do
    Phoenix.PubSub.broadcast(MWTClient.PubSub, @topic, {:mwt_update, public_state(state)})
    state
  end
end
