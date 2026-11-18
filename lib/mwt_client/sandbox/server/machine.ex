defmodule MWTClient.Sandbox.Server.Machine do
  @moduledoc """
  The VM and its image, in the sandbox server's state: creating, starting,
  stopping and recreating the VM in its bubble, its disks and their copies,
  seeding its memory, building the image, and noticing what changed while
  nobody looked.

  The slow work (`msb`, podman, copying disks) runs in tasks; what is here
  starts them and takes their results. Runs in the server's process
  (`MWTClient.Sandbox.Server.State`).
  """

  require Logger

  alias MWTClient.Sandbox.{
    Bubble,
    Build,
    Disks,
    FolderSync,
    Guest,
    Image,
    Inbox,
    Memory,
    MemoryControl,
    Msb,
    NestedVirt,
    VM
  }

  alias MWTClient.Sandbox.Server.{Copying, HostRuns, State}

  @build_log_limit 400

  @doc """
  The launcher Zed's SSH config names; a failure only matters there. A
  missing runtime is shown in the UI already.
  """
  def write_launcher(username) do
    case Msb.write_launcher(username) do
      :ok ->
        :ok

      {:error, :no_runtime} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not write the msb launcher: #{inspect(reason)}", system: :sandbox)
    end
  end

  @doc """
  What is missing on this machine for a VM to run, in words for the user.
  """
  def needs do
    bubble =
      case Bubble.available() do
        :ok -> []
        {:error, message} -> [message]
      end

    relay = if Bubble.relay(), do: [], else: ["MWT's relay is missing from this build."]

    disks =
      case Disks.missing_tools() do
        [] -> []
        tools -> ["#{Enum.join(tools, ", ")} not found (package e2fsprogs)."]
      end

    bubble ++ relay ++ disks
  end

  @doc """
  Starts one of the VM's actions (start, stop, a copy of Home and the like) in a task, with `busy` as what the pages show meanwhile.
  """
  def vm_task(state, action, busy) do
    state = state |> State.write_inbox() |> State.change(:vm, &%{&1.vm | busy: busy, error: nil})

    # A VM made before MWT kept records gets one now, for its boot to write.
    state =
      if action == :start and is_nil(State.vm_record(state)),
        do: State.changed(Map.put(state, :vm_record, record(nil, state.created_ref, false))),
        else: state

    record = State.vm_record(state)
    name = state.vm.name
    username = state.username
    folders = state.folders
    sizes = disk_sizes(state.settings)
    bubble = bubble_spec(state, record)
    grants = state.grants
    job = boot_job(state, record, false)
    memory_gib = state.settings.memory_gib
    server = self()

    work =
      case action do
        :start ->
          fn ->
            :ok = Copying.drain(server)

            with :ok <- prepare(folders, sizes, bubble),
                 # Best effort: a VM that keeps an old export still starts.
                 # It is logged, and only costs public downloads their
                 # anonymity until the next start.
                 _cleared <- clear_legacy_env(username, name, grants),
                 {:ok, _} <- MemoryControl.prepare(username, name, memory_gib),
                 {:ok, output} <- Bubble.start(bubble, ["start", name], 120),
                 {:ok, _} <- Bubble.resize_memory(username, memory_gib * 1024) do
              {:ok, output, boot(job)}
            end
          end

        :stop ->
          fn ->
            with {:ok, _output} = stopped <- Bubble.stop(username),
                 :ok <- Copying.drain(server),
                 do: stopped
          end
      end

    State.task(state, {:vm, action}, work)
  end

  @doc """
  Gives the host back the space the VM's disks hold for what it deleted
  (`Disks.reclaim!/1`), in a task, with the VM stopped and busy meanwhile.
  """
  def reclaim(state) do
    folders = state.folders
    server = self()

    work = fn ->
      :ok = Copying.drain(server)

      try do
        results =
          for name <- Disks.names(),
              path = Map.fetch!(folders, name),
              File.regular?(path),
              do: {name, Disks.reclaim!(path)}

        {:ok, results}
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    state
    |> State.change(:vm, &%{&1.vm | busy: "Reclaiming disk space…", error: nil})
    |> State.task({:vm, :reclaim}, work)
  end

  @create_defaults %{home: :keep, cache: :keep, seed_memory: false}

  @doc """
  Creating (or recreating) the VM: stop it, snapshot Home, apply what you
  chose for Home, Cache and the VM's memory, prepare the folders, then
  `msb create --replace`. All of it in a task, with the VM stopped.
  """
  def create(state, options, busy) do
    options = Map.merge(@create_defaults, options || %{})

    with :ok <- check_options(state, options) do
      state =
        state |> State.write_inbox() |> State.change(:vm, &%{&1.vm | busy: busy, error: nil})

      spec = vm_spec(state)
      args = Msb.create_args(Map.put(spec, :env, []))

      record = record(State.now(), state.image.tag, true)

      job = %{
        server: self(),
        username: state.username,
        name: state.vm.name,
        existed?: state.vm.exists?,
        folders: state.folders,
        sizes: disk_sizes(state.settings),
        bubble: bubble_spec(state, record),
        snapshots: state.snapshots,
        snapshot_tag: tag_of(state.created_ref),
        ref: state.image.tag,
        record: record,
        boot: boot_job(state, record, options.seed_memory),
        spec: :erlang.phash2(spec),
        args: args,
        options: options
      }

      {:reply, :ok, State.task(state, {:vm, :create}, fn -> run_create(job) end)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp check_options(state, options) do
    cond do
      options.home not in [:keep, :empty] and
          not match?({:snapshot, id} when is_binary(id), options.home) ->
        {:error, :bad_options}

      match?({:snapshot, _}, options.home) and
          not Enum.any?(state.snapshots, &({:snapshot, &1.id} == options.home)) ->
        {:error, :no_snapshot}

      options.cache not in [:keep, :clear] ->
        {:error, :bad_options}

      options.seed_memory == true and not Memory.host_memory?() ->
        {:error, :no_memory}

      # microsandbox would make the VM and then refuse to boot it.
      state.settings.nested_virt and NestedVirt.host() != :allowed ->
        {:error, {:no_nested_virt, NestedVirt.host()}}

      true ->
        :ok
    end
  end

  defp run_create(job) do
    # A clean stop first: the disks are copied and changed below, and a disk
    # the VM still writes must not be.
    {:ok, _} = Bubble.stop(job.username)
    # Copy commands address the VM by its reused name. None of the old
    # tasks may still issue one when the replacement starts.
    :ok = Copying.drain(job.server)
    Disks.ensure!(job.folders, job.sizes)

    # Home is copied before anything changes it, so emptying it or going back
    # to an older snapshot can be undone.
    {snapshots, taken} =
      if job.existed? do
        snapshot = Disks.snapshot!(job.folders, job.snapshot_tag, State.now())
        {[snapshot | job.snapshots], snapshot}
      else
        {job.snapshots, nil}
      end

    outcome =
      try do
        case job.options.home do
          :keep -> :ok
          :empty -> Disks.empty!(job.folders.home)
          {:snapshot, id} -> Disks.restore!(job.folders, Enum.find(snapshots, &(&1.id == id)))
        end

        if job.options.cache == :clear, do: Disks.empty!(job.folders.cache)

        with :ok <- prepare(job.folders, job.sizes, job.bubble),
             {:ok, output} <- Bubble.start(job.bubble, job.args, 300),
             {:ok, _} <- Bubble.resize_memory(job.username, job.bubble.memory_gib * 1024) do
          {{:ok, output}, boot(job.boot)}
        else
          error -> {error, nil}
        end
      rescue
        error -> {{:error, Exception.message(error)}, nil}
      end

    {kept, removed} = Disks.keep(snapshots, kept_count(job.username, "vm_snapshots"))
    Enum.each(removed, &Disks.delete!(job.folders, &1))
    {result, booted} = outcome

    %{
      result: result,
      spec: job.spec,
      ref: job.ref,
      record: job.record,
      snapshots: kept,
      taken: taken,
      booted: booted,
      options: job.options
    }
  end

  # Before every start: the disks exist, at least as big as the settings
  # say, and so do the folders a VM made before 2026-11-16 mounts. The VM is
  # stopped meanwhile. MWT writes nothing into any of them.
  defp prepare(folders, sizes, bubble) do
    Disks.ensure!(folders, sizes)
    if legacy = bubble[:legacy], do: Enum.each([legacy.inbox, legacy.optmem], &File.mkdir_p!/1)
    :ok
  rescue
    error -> {:error, "Preparing the VM's disks failed: " <> Exception.message(error)}
  end

  # Which VM this is, for the boot script to write into it: a new id each
  # time MWT creates one. `copied` for one made since 2026-11-16, with
  # nothing of this machine mounted.
  defp record(created_at, image, copied) do
    %{
      id: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower),
      created_at: created_at,
      image: image,
      copied: copied
    }
  end

  defp boot_job(state, record, seed?) do
    %{
      username: state.username,
      name: state.vm.name,
      record: record,
      inbox: State.inbox_dir(state),
      dir: state.dir,
      optmem: state.folders.optmem,
      seed?: seed?
    }
  end

  # After every boot, in the VM, before anything there reads them: MWT's
  # files at /mnt/mwt, the memory a VM made before 2026-11-16 kept here, a
  # copy of yours when you asked for one; then the boot script, which copies
  # for itself what MWT has for it (the agents' instructions, the memo
  # tool). A VM whose image can't run the script still runs; the same text
  # is at /mnt/mwt/AGENTS.md. What went wrong is in the result, for the page.
  defp boot(job) do
    inbox =
      Inbox.record(job.inbox, job.record.id)
      |> Inbox.into_vm(job.username, job.name, job.dir, fresh: true)

    guest = Guest.vm(job.username, job.name)
    moved = Memory.move_in(guest, job.optmem)
    seed = if job.seed?, do: Memory.seed(guest)

    created = if job.record.created_at, do: DateTime.to_iso8601(job.record.created_at), else: ""
    args = [job.record.id, created, job.record.image || "", job.name]

    case Msb.run(job.username, ["exec", job.name, "--", "/mnt/mwt/bin/mwt-boot" | args], 60) do
      {:ok, _output} ->
        :ok

      {:error, message} ->
        Logger.warning("the VM's boot script failed: #{String.slice(message, 0, 300)}",
          system: :sandbox
        )
    end

    %{inbox: inbox, moved: moved, seed: seed}
  end

  # What a boot did, into the state: the copy of /mnt/mwt the sync goes on
  # from, the memory, and what failed, as the VM's error.
  defp booted(state, nil), do: state

  defp booted(state, booted) do
    state = %{state | inbox_sync: booted.inbox, inbox_due: false}

    state =
      case booted.moved do
        :moved ->
          State.log(state, %{outcome: :vm, summary: "The VM's memory moved onto its own disk"})

        _ ->
          state
      end

    state =
      case booted.seed do
        {:ok, count} -> seeded(state, count)
        _ -> state
      end

    errors =
      [
        booted.inbox.status.error &&
          "MWT's files couldn't be put in the VM at /mnt/mwt: " <> booted.inbox.status.error,
        match?({:error, _}, booted.moved) && elem(booted.moved, 1),
        match?({:error, _}, booted.seed) && elem(booted.seed, 1)
      ]
      |> Enum.filter(&is_binary/1)

    state = Copying.answer_waiters(state)

    if errors == [],
      do: state,
      else: State.change(state, :vm, &%{&1.vm | error: Enum.join(errors, " ")})
  end

  # Every boot gets a whole comparison, without a delay from the previous
  # one. A timer may already have ticked while the VM was still busy.
  defp reset_sync(state) do
    send(self(), :sync)

    %{state | sync_after: nil}
    |> State.change(:sync, fn _ -> %{} end)
  end

  defp disk_sizes(settings),
    do: %{
      home: settings.home_gib,
      cache: settings.cache_gib,
      work: settings.work_gib,
      memory: Disks.memory_gib()
    }

  # A VM made before 2026-11-16 mounts MWT's files and its memory from
  # folders here: its bubble has them until it is recreated.
  defp bubble_spec(state, record) do
    legacy =
      if not Map.get(record || %{}, :copied, false),
        do: %{inbox: State.inbox_dir(state), optmem: state.folders.optmem}

    %{
      username: state.username,
      name: state.vm.name,
      disks: state.folders.dir,
      memory_gib: state.settings.memory_gib,
      legacy: legacy
    }
  end

  @doc """
  Copies your memory into the running VM's, in a task. With `expect`, the
  size of the VM's log you reviewed, only if the VM noted nothing since.
  """
  def seed_task(state, expect \\ nil) do
    guest = Guest.vm(state.username, state.vm.name)

    state
    |> State.change(:vm, &%{&1.vm | busy: "Copying your memory…", error: nil})
    |> State.task(:seed_memory, fn ->
      try do
        Memory.seed(guest, expect)
      rescue
        error -> {:error, Exception.message(error)}
      end
    end)
  end

  # What the VM is created with. Changing any of it means recreating the VM;
  # the disks' sizes are not here, since a disk grows at the next start.
  defp vm_spec(state) do
    spec = %{
      name: state.vm.name,
      image: state.image.tag,
      shell: "/bin/bash",
      cpus: state.settings.cpus,
      memory_gib: state.settings.memory_gib,
      disk_gib: state.settings.disk_gib,
      # Nothing of this machine is mounted: shared folders and /mnt/mwt are
      # copied in while it runs, so they aren't part of what it is made of,
      # and its memory is a disk. A VM made with folders mounted is stale
      # until recreated (2026-11-16).
      mounts: :none
    }

    # Only when on, so a VM made before the setting existed keeps the spec it
    # was made with and isn't taken for stale.
    if state.settings.nested_virt, do: Map.put(spec, :nested_virt, true), else: spec
  end

  defp tag_of(nil), do: nil

  defp tag_of(ref) do
    case String.split(ref, ":", parts: 2) do
      [_name, tag] -> tag
      [ref] -> ref
    end
  end

  @doc """
  Whether the VM was created from other settings than the ones you have now.
  """
  def stale?(%{vm: %VM{exists?: false}}), do: false

  def stale?(state),
    do: not is_nil(state.created_spec) and state.created_spec != :erlang.phash2(vm_spec(state))

  @doc """
  Asks microsandbox and the relay how the VM and the image are, in a task.
  """
  def check(state, options \\ []) do
    username = state.username
    name = state.vm.name
    tag = state.image.tag
    grants = state.grants

    State.task(state, :check, fn ->
      status = vm_status(username, name)

      cleanup =
        if Keyword.get(options, :clear_legacy_env, false) and match?({:ok, _}, status),
          do: clear_legacy_env(username, name, grants),
          else: :ok

      %{status: status, image?: Msb.image?(username, tag), env_cleanup: cleanup}
    end)
  end

  # Whether the VM runs is its relay's to say; whether it exists at all,
  # microsandbox's records.
  defp vm_status(username, name) do
    case Bubble.status(username) do
      :down ->
        case Msb.status(username, name) do
          :exists -> {:ok, :stopped}
          other -> other
        end

      up ->
        {:ok, up}
    end
  end

  @doc """
  Takes the result of a task that `vm_task/3`, `create/3`, `seed_task/1` or `check/1` started.
  """
  def finished(state, :check, %{status: status, image?: image?} = result) do
    vm =
      case status do
        {:ok, status} -> %{state.vm | exists?: true, status: status}
        :missing -> %{state.vm | exists?: false, status: :stopped}
        {:error, message} -> %{state.vm | error: message}
      end

    vm =
      if vm.status == :running and is_nil(state.vm.started_at),
        do: %{vm | started_at: State.now()},
        else: vm

    vm = if vm.status != :running, do: %{vm | started_at: nil}, else: vm

    vm =
      case result[:env_cleanup] do
        {:error, message} -> %{vm | error: "Removing old credential exports failed: #{message}"}
        _ -> vm
      end

    state =
      if vm.status == :running and state.vm.status != :running,
        do: reset_sync(state),
        else: state

    state
    |> State.change(:vm, fn _ -> vm end)
    |> State.change(:image, fn state ->
      if state.image.building?, do: state.image, else: %{state.image | loaded?: image?}
    end)
  end

  def finished(state, :check, _crashed), do: state

  def finished(state, {:vm, :create}, %{} = done) do
    state =
      state
      |> State.change(:snapshots, fn _ -> done.snapshots end)
      |> State.changed()

    state =
      if done.taken,
        do:
          State.log(state, %{
            outcome: :vm,
            summary: "Home copied before recreating (#{done.taken.id})"
          }),
        else: state

    case done.result do
      {:ok, _output} ->
        state
        |> reset_sync()
        |> Map.merge(%{created_spec: done.spec, created_ref: done.ref, vm_record: done.record})
        |> State.change(
          :vm,
          &%{
            &1.vm
            | busy: nil,
              exists?: true,
              status: :running,
              started_at: State.now(),
              error: nil
          }
        )
        |> State.log(%{
          outcome: :vm,
          summary: "VM created from #{done.ref} and started#{create_words(done.options)}"
        })
        |> booted(done.booted)
        |> State.changed()

      error ->
        finished(state, {:vm, :create_failed}, error)
    end
  end

  def finished(state, :seed_memory, result) do
    case result do
      {:ok, count} ->
        state
        |> State.change(:vm, &%{&1.vm | busy: nil})
        |> seeded(count)
        |> State.changed()

      {:error, :moved_on} ->
        State.change(
          state,
          :vm,
          &%{
            &1.vm
            | busy: nil,
              error:
                "The VM noted more while you reviewed, so its memory was left as it is. Sync again to see what it added."
          }
        )

      {:error, message} ->
        state
        |> State.change(
          :vm,
          &%{&1.vm | busy: nil, error: message}
        )
        |> State.log(%{outcome: :vm, summary: "Copying your memory into the VM failed"})
    end
  end

  def finished(state, {:vm, :start}, {:ok, _output, booted}) do
    state
    |> reset_sync()
    |> State.change(
      :vm,
      &%{&1.vm | busy: nil, status: :running, started_at: State.now(), error: nil}
    )
    |> State.log(%{outcome: :vm, summary: "VM started"})
    |> booted(booted)
  end

  def finished(state, {:vm, :stop}, {:ok, _output}) do
    %{state | inbox_sync: nil}
    |> State.change(:vm, &%{&1.vm | busy: nil, status: :stopped, started_at: nil, error: nil})
    |> State.log(%{outcome: :vm, summary: "VM stopped"})
    |> Copying.answer_waiters()
  end

  def finished(state, {:vm, :reclaim}, {:ok, results}) do
    freed = results |> Enum.map(fn {_disk, r} -> max(r.before - r.after, 0) end) |> Enum.sum()

    state
    |> State.change(:vm, &%{&1.vm | busy: nil, error: nil, reclaimed: results})
    |> State.log(%{
      outcome: :vm,
      summary: "Disk space reclaimed: #{div(freed, 1_048_576)} MB freed"
    })
  end

  def finished(state, {:vm, action}, result) do
    message =
      case result do
        {:error, message} -> message
        other -> inspect(other)
      end

    state
    |> State.change(:vm, &%{&1.vm | busy: nil, error: message})
    |> State.log(%{
      outcome: :vm,
      summary: "msb #{action} failed: #{String.slice(message, 0, 200)}"
    })
    |> check()
  end

  def finished(state, {:check, grant_id, check_id}, result),
    do: MWTClient.Sandbox.Server.Checks.finished(state, {grant_id, check_id}, result)

  # `key` is the grant's id, or `{id, host}` for one minted per host
  # (`Values.mint_key/2`). A value is kept until it stops being fresh.
  def finished(state, {:mint, key}, result) do
    {continuations, minting} = Map.pop(state.minting, key, [])

    state = %{state | minting: minting}

    {state, result} =
      case result do
        {:ok, value, fresh_ms} ->
          until = System.monotonic_time(:millisecond) + fresh_ms
          {%{state | minted: Map.put(state.minted, key, {value, until})}, {:ok, value}}

        other ->
          {state, other}
      end

    Enum.reduce(continuations, state, fn k, acc -> k.(acc, result) end)
  end

  def finished(state, {:command, approval_id}, %{} = result),
    do: HostRuns.finished_command(state, approval_id, result)

  def finished(state, {:command, approval_id}, {:error, message}),
    do: HostRuns.finished_command(state, approval_id, %{error: message})

  def finished(state, :probe_host, tools) when is_list(tools) do
    state
    |> State.change(:host, &%{&1.host | tools: tools, probed_at: State.now(), probing?: false})
    |> State.write_host()
  end

  def finished(state, :probe_host, _crashed),
    do: State.change(state, :host, &%{&1.host | probing?: false})

  # A task from before credential scoping may finish during a dev reload.
  def finished(state, :env, _result), do: state

  # The mirror task tells the server what it did as it goes.
  def finished(state, :mirror, _result), do: state

  # A shared folder no longer shared is dropped; a look that took long
  # spaces the next one out, twice as long again.
  def finished(state, :sync, %{
        vm: vm,
        started_at: started_at,
        records: records,
        took: took
      }) do
    # A copy can end after the VM was stopped or recreated. Its result and
    # delay belong to that boot, not the VM running now.
    # OptMem sync only makes this boot busy: keep its completed imports.
    if match?(%{id: ^vm, copied: true}, State.vm_record(state)) and
         state.vm.status == :running and
         state.vm.started_at == started_at do
      paths = MapSet.new(state.settings.shares, & &1.path)
      records = Map.filter(records, fn {path, _} -> MapSet.member?(paths, path) end)
      shown = &Map.new(&1, fn {path, record} -> {path, FolderSync.shown(record)} end)
      state = %{state | sync_after: System.monotonic_time(:millisecond) + 2 * took}

      if shown.(records) == shown.(state.sync),
        do: %{state | sync: records},
        else: State.change(state, :sync, fn _ -> records end)
    else
      state
    end
  end

  # A copy already running when the layout check was added has no boot id.
  def finished(state, :sync, %{records: _records, took: _took}), do: state

  def finished(state, :sync_inbox, result), do: Copying.finished(state, result)

  def finished(state, :sync, {:error, message}) do
    Logger.warning("copying the shared folders failed: #{message}", system: :sandbox)
    state
  end

  def finished(state, :delete_builds, _result), do: state

  defp seeded(state, nil), do: state

  defp seeded(state, count) do
    state
    |> State.change(:memory, fn _ ->
      %{seed_count: count, seeded_at: State.now(), reviewed: count}
    end)
    |> State.log(%{
      outcome: :vm,
      summary: "The VM's memory now starts from yours (#{count} memories)"
    })
  end

  defp create_words(options) do
    words =
      Enum.reject(
        [
          options.home == :empty && "Home emptied",
          match?({:snapshot, _}, options.home) && "Home from a snapshot",
          options.cache == :clear && "Cache cleared",
          options.seed_memory && "memory copied from yours"
        ],
        &(&1 == false)
      )

    if words == [], do: "", else: " · " <> Enum.join(words, ", ")
  end

  @doc """
  Removes the credential exports older MWT versions put in the VM's saved
  environment. Existing processes keep their environment until reconnected;
  no process is killed and the VM doesn't need recreation.
  """
  def clear_legacy_env(username, name, grants) do
    args =
      grants
      |> Inbox.env()
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.flat_map(&["--env-rm", &1])

    case args do
      [] ->
        :ok

      _ ->
        # The runtime cannot update exec defaults live. Persist this for
        # the next boot without stopping a user's running VM.
        case Msb.run(username, ["modify", name, "--next-start" | args], 30) do
          {:ok, _} ->
            :ok

          {:error, message} = error ->
            Logger.warning("could not remove legacy VM credential exports: #{message}",
              system: :sandbox
            )

            error
        end
    end
  end

  @doc """
  Where the image is built.
  """
  def build_dir(state), do: Path.join(state.dir, "build")

  @doc """
  Starts building the image, in a task that sends podman's output line by line.
  """
  def start_build(state) do
    dir = build_dir(state)
    name = state.settings.image_name
    today = NaiveDateTime.local_now() |> NaiveDateTime.to_date()
    tag = Image.next_tag(name, today, state.builds)
    ref = "#{name}:#{tag}"
    Image.write_context(dir, state.settings.containerfile)

    building = %{
      name: name,
      tag: tag,
      containerfile: state.settings.containerfile,
      built_at: State.now()
    }

    # The image is loaded by the confined msb, which must be written.
    port =
      _ = Msb.write_launcher(state.username)

    Port.open({:spawn_executable, System.find_executable("bash")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 2_000},
      args: ["-c", Image.build_script(dir, ref)],
      env:
        Enum.map(Msb.env(state.username), fn {k, v} ->
          {String.to_charlist(k), String.to_charlist(v)}
        end)
    ])

    %{state | build: port}
    |> State.change(
      :image,
      &%{&1.image | building?: true, building: building, error: nil, log: []}
    )
    |> State.log(%{outcome: :vm, summary: "Building image #{ref}"})
  end

  @doc """
  A finished build becomes current. Builds beyond the newest the
  `vm_images` rule keeps go, except the one the VM was created from.
  """
  def built(state, %Build{} = build) do
    builds = [build | Enum.reject(state.builds, &(&1.ref == build.ref))]

    {kept, removed} =
      Image.keep(
        builds,
        Enum.reject([state.created_ref], &is_nil/1),
        kept_count(state.username, "vm_images")
      )

    state =
      state
      |> State.change(:builds, fn _ -> kept end)
      |> State.change(
        :image,
        &%{&1.image | tag: build.ref, loaded?: true, building?: false, building: nil, error: nil}
      )
      |> State.log(%{outcome: :vm, summary: "Image #{build.ref} built"})
      |> State.changed()

    if removed == [] do
      state
    else
      refs = Enum.map(removed, & &1.ref)
      username = state.username

      state
      |> State.log(%{outcome: :vm, summary: "Older images deleted: #{Enum.join(refs, ", ")}"})
      |> State.task(:delete_builds, fn -> Enum.each(refs, &Image.delete(username, &1)) end)
    end
  end

  @doc """
  Adds a line of the build's output to its log, which keeps the last 400.
  """
  def build_line(state, line) do
    image = %{state.image | log: Enum.take([line | state.image.log], @build_log_limit)}
    State.broadcast(state, {:sandbox_build_line, line})
    %{state | image: image}
  end

  # How many of a kind the VM's retention rule keeps (`MWTClient.Storage.Retention`);
  # with the rule off, every one.
  defp kept_count(username, key) do
    case MWTClient.Storage.Retention.rule(username, key).count do
      nil -> 1_000_000
      count -> count
    end
  end
end
