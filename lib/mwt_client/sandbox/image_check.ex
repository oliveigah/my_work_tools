defmodule MWTClient.Sandbox.ImageCheck do
  @moduledoc """
  Whether the image a VM runs from holds the files its build made.

  microsandbox turns a build into a read-only EROFS disk, the VM's
  `/dev/vda`, under the overlay that is its root. Once, on 2026-11-23, a
  file there read as zeros past its first 24 MiB though the build was
  intact: nothing noticed, and every tool behind that file crashed at its entry point.

  MWT's final layer lists the checksum of every file in the image
  (`/etc/mwt/image.sha256`, `MWTClient.Sandbox.Image`). After a VM's first
  start, this check mounts the image disk read-only in the VM, apart from
  its root, and checks every file against that list (`run/1`): what the
  VM wrote since doesn't count, only what microsandbox put on the disk.
  About 7 to 20 s for an image of 5 GB, in a task of its own.

  The VM reports what it found, so a VM could lie about it: this catches a
  damaged image, not a hostile VM.

  The result (`t:result/0`) goes on the VM's record, which a recreate
  replaces: each VM is checked once, after its first start.
  """

  @typedoc """
  What the check found: `:intact`; `{:damaged, files, count}`, the first
  files that differ, and how many differ (0 when the list itself couldn't
  be read); `{:unchecked, why}`, when there was nothing to check against
  (an image built before the list); `{:failed, why}`, when the check
  itself couldn't run.
  """
  @type result ::
          :intact
          | {:damaged, [String.t()], non_neg_integer()}
          | {:unchecked, String.t()}
          | {:failed, String.t()}

  # Most files a result names: enough to see what broke.
  @shown 20

  # Run in the VM, as root. With a folder (tests), it checks that folder;
  # in a VM, the read-only EROFS disk among its block devices, mounted
  # where nothing else looks. Prints one line of result first, then, when
  # damaged, the files that differ.
  @script ~S"""
  set -u
  shown=$2
  work=$(mktemp -d /tmp/mwt-image-check.XXXXXX) || { echo "failed no folder to work in"; exit 0; }
  root=$1
  if [ -z "$root" ]; then
    root=$work/image
    mkdir "$root"
    trap 'umount "$root" 2>/dev/null; rm -rf "$work"' EXIT
    mounted=""
    for block in /sys/block/*; do
      [ "$(cat "$block/ro" 2>/dev/null)" = 1 ] || continue
      if mount -t erofs -o ro "/dev/${block##*/}" "$root" 2>/dev/null; then
        mounted=1
        break
      fi
    done
    [ -n "$mounted" ] || { echo "failed no read-only image disk was found to mount"; exit 0; }
  else
    trap 'rm -rf "$work"' EXIT
  fi
  cd "$root" || { echo "failed the image couldn't be opened"; exit 0; }
  [ -f etc/mwt/image.sha256 ] ||
    { echo "unchecked its build has no checksum list: it was built before MWT made one"; exit 0; }
  if sha256sum -c --quiet etc/mwt/image.sha256 > "$work/failed" 2>/dev/null; then
    echo intact
  else
    echo "damaged $(grep -c . "$work/failed")"
    head -n "$shown" "$work/failed"
  fi
  """

  @doc """
  Checks the image of the VM behind `guest`, or, given `root`, that
  folder, as tests do.
  """
  @spec run(map(), Path.t() | nil) :: result()
  def run(guest, root \\ nil) do
    case guest.exec.(["bash", "-c", @script, "mwt-image-check", root || "", "#{@shown}"]) do
      {:ok, output} -> parse(output)
      {:error, message} -> {:failed, message}
    end
  end

  @doc """
  The result the check printed.

      iex> MWTClient.Sandbox.ImageCheck.parse("intact\\n")
      :intact
      iex> MWTClient.Sandbox.ImageCheck.parse("damaged 1\\n./usr/local/bin/mise: FAILED\\n")
      {:damaged, ["/usr/local/bin/mise"], 1}
      iex> MWTClient.Sandbox.ImageCheck.parse("unchecked no list\\n")
      {:unchecked, "no list"}
  """
  @spec parse(String.t()) :: result()
  def parse(output) do
    case String.split(output, "\n", trim: true) do
      ["intact" | _] ->
        :intact

      ["damaged " <> count | lines] ->
        files = Enum.map(lines, &file/1)

        case Integer.parse(count) do
          {count, ""} -> {:damaged, files, count}
          _other -> {:failed, "the check printed #{inspect(String.slice(output, 0, 200))}"}
        end

      ["unchecked " <> why | _] ->
        {:unchecked, why}

      ["failed " <> why | _] ->
        {:failed, why}

      _other ->
        {:failed, "the check printed #{inspect(String.slice(output, 0, 200))}"}
    end
  end

  # `./usr/bin/x: FAILED` or `./usr/bin/x: FAILED open or read`, as the
  # VM's path.
  defp file(line) do
    line
    |> String.replace(~r/: FAILED.*\z/, "")
    |> String.replace_prefix(".", "")
  end

  @doc "What a result says, for the VM's page and the activity log."
  @spec explain(result()) :: String.t()
  def explain(:intact), do: "Every file of the image is as its build made it."

  def explain({:damaged, [], _count}),
    do:
      "The image's checksum list couldn't be read: it may be damaged itself. " <>
        "Rebuild the image without podman's cache, then recreate the VM."

  def explain({:damaged, files, count}) do
    more = if count > length(files), do: ", and #{count - length(files)} more", else: ""

    "#{count} #{if count == 1, do: "file", else: "files"} of the image differ from its build: " <>
      Enum.join(files, ", ") <>
      more <>
      ". Tools there may crash. Rebuild the image without podman's cache, then recreate the VM."
  end

  def explain({:unchecked, why}), do: "Not checked: #{why}."
  def explain({:failed, why}), do: "The check couldn't run: #{why}."
end
