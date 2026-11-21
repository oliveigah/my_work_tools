defmodule MWTClient.Sandbox.Settings do
  @moduledoc """
  How the VM is built. Changing the image or resources of a VM that exists
  means recreating it; shared folders are copied in while it runs, so
  changing them doesn't.
  `image_name` only names the next build. `host_notes` is your own text
  about this machine, which agents read with the rest of `mwt host`.

  `cpus` and `memory_gib` start at what this machine can spare, and can't
  go past what it can give (`MWTClient.Sandbox.Resources`); the defaults
  here are only for a struct made without them.

  `memory_gib` is a ceiling. MemoryControl gives the VM a smaller boot
  allocation and uses microsandbox's live hotplug controls for the rest.

  Disk comes in three kinds, all sparse images that take host space only as
  they fill. `disk_gib` sizes the VM's root disk, which starts empty on
  every recreate. `home_gib`, `cache_gib` and `work_gib` size the disks the
  VM keeps (`MWTClient.Sandbox.Disks`); making one bigger applies at the
  next start, and none is ever made smaller. The VM writes no folder of
  this machine: shared folders are copied into it
  (`MWTClient.Sandbox.FolderSync`), and its memory is a disk of its own.
  microsandbox's own default is 4 GiB for the root disk.

  `confine_reads` are the folders of your home a confined command may
  read (`MWTClient.Sandbox.Confine`): where your tools live. Nil, they are
  those your login shell's `PATH` runs tools from.

  `nested_virt` lets the VM run VMs of its own (`MWTClient.Sandbox.NestedVirt`),
  at the cost of exposing more of this machine's KVM to it; off unless you
  turn it on, and it applies when the VM is recreated.

  `way_of_working` is your own text on how you like to work with agents:
  which decisions to bring you, how you like a system built. Your taste,
  not a fact of the VM, so empty until you write it; MWT offers an example
  to start from (`priv/sandbox/way-of-working-example.md`). Agents read it
  after MWT's instructions, from the VM's next start, when its boot script
  writes them again.
  """

  alias MWTClient.Sandbox.{Image, Share}

  defstruct containerfile: nil,
            image_name: "mwt_agent_sdb_image",
            cpus: 4,
            memory_gib: 8,
            disk_gib: 64,
            home_gib: 16,
            cache_gib: 64,
            work_gib: 64,
            hold_seconds: 180,
            nested_virt: false,
            way_of_working: "",
            shares: [],
            host_notes: "",
            confine_reads: nil

  @type t :: %__MODULE__{
          containerfile: String.t() | nil,
          image_name: String.t(),
          cpus: pos_integer(),
          memory_gib: pos_integer(),
          disk_gib: pos_integer(),
          home_gib: pos_integer(),
          cache_gib: pos_integer(),
          work_gib: pos_integer(),
          hold_seconds: pos_integer(),
          nested_virt: boolean(),
          way_of_working: String.t(),
          shares: [Share.t()],
          host_notes: String.t(),
          confine_reads: [String.t()] | nil
        }

  @doc """
  The settings with what a form sent, checked: `{:ok, settings}`, or
  `{:error, errors}` with a message for each field that is wrong. A field
  the form didn't send stays as it is.

  `most` caps the CPUs and memory at what this machine can give
  (`MWTClient.Sandbox.Resources.most/1`); without it, only at what
  microsandbox takes.
  """
  @spec cast(t(), map(), %{cpus: pos_integer(), memory_gib: pos_integer()}) ::
          {:ok, t()} | {:error, %{atom() => String.t()}}
  def cast(%__MODULE__{} = settings, attrs, most \\ %{cpus: 64, memory_gib: 512}) do
    fields = [
      {:cpus, attrs["cpus"], &cast_int(&1, 1, most.cpus)},
      {:memory_gib, attrs["memory_gib"], &cast_int(&1, 1, most.memory_gib)},
      {:disk_gib, attrs["disk_gib"], &cast_int(&1, 4, 4096)},
      {:hold_seconds, attrs["hold_seconds"], &cast_int(&1, 30, 600)},
      {:home_gib, attrs["home_gib"], &cast_int(&1, 1, 4_096)},
      {:cache_gib, attrs["cache_gib"], &cast_int(&1, 1, 4_096)},
      {:work_gib, attrs["work_gib"], &cast_int(&1, 1, 4_096)},
      {:nested_virt, attrs["nested_virt"], &cast_boolean/1},
      {:way_of_working, attrs["way_of_working"], &cast_way_of_working/1},
      {:containerfile, attrs["containerfile"], &cast_containerfile/1},
      {:image_name, attrs["image_name"], &cast_image_name/1},
      {:host_notes, attrs["host_notes"], &cast_notes/1},
      {:confine_reads, attrs["confine_reads"], &cast_reads/1}
    ]

    {changes, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn
        {_field, nil, _cast}, acc ->
          acc

        {field, value, cast}, {changes, errors} ->
          case cast.(value) do
            {:ok, cast_value} -> {Map.put(changes, field, cast_value), errors}
            {:error, message} -> {changes, Map.put(errors, field, message)}
          end
      end)

    if errors == %{}, do: {:ok, struct!(settings, changes)}, else: {:error, errors}
  end

  defp cast_containerfile(value) do
    if Regex.match?(~r/^\s*FROM\s+\S+/mi, value),
      do: {:ok, String.replace(value, "\r\n", "\n")},
      else: {:error, "A Containerfile needs a FROM line."}
  end

  # The folders confined commands may read, one a line; none written is
  # back to those your login shell's PATH runs tools from.
  defp cast_reads(value) do
    folders =
      value
      |> String.split(["\n", ","])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      folders == [] ->
        {:ok, nil}

      bad = Enum.find(folders, &(not String.starts_with?(&1, ["/", "~/"]))) ->
        {:error, "#{bad}: write a whole path, starting with / or ~/."}

      length(folders) > 50 ->
        {:error, "At most 50 folders."}

      true ->
        {:ok, folders |> Enum.map(&Path.expand/1) |> Enum.uniq()}
    end
  end

  defp cast_notes(value) do
    notes = value |> String.replace("\r\n", "\n") |> String.trim()

    if String.length(notes) <= 4_000,
      do: {:ok, notes},
      else: {:error, "Keep notes under 4,000 characters."}
  end

  # Read by agents in every session: long enough for a guide, short enough
  # not to crowd out their work.
  defp cast_way_of_working(value) do
    text = value |> String.replace("\r\n", "\n") |> String.trim()

    if String.length(text) <= 20_000,
      do: {:ok, text},
      else: {:error, "Keep it under 20,000 characters."}
  end

  defp cast_image_name(value) do
    name = String.trim(value)

    if Image.valid_name?(name),
      do: {:ok, name},
      else:
        {:error, "Lowercase letters and digits, joined by single dots, underscores or dashes."}
  end

  defp cast_boolean(value) when value in [true, "true"], do: {:ok, true}
  defp cast_boolean(value) when value in [false, "false"], do: {:ok, false}
  defp cast_boolean(_value), do: {:error, "Choose on or off."}

  defp cast_int(value, min, max) do
    case Integer.parse(String.trim(to_string(value))) do
      {int, ""} when int >= min and int <= max -> {:ok, int}
      _ -> {:error, "Enter a whole number from #{min} to #{max}."}
    end
  end
end
