defmodule MWTClient.Sandbox.ShareMounts do
  @moduledoc """
  Where the copies of your shared folders live in the VM, and how they are
  shown there: read-only, at the same path as on your machine.

  Each share's copy is kept on the VM's work disk, in a folder of its own
  (`store/1`): `/work/.shares/ID/files`, beside `/work/.shares/ID/at`,
  which names the path it is shown at. MWT writes the copy there
  (`MWTClient.Sandbox.FolderSync`), and a read-only bind mount shows it at
  the share's path. So a program in the VM that tries to change a shared
  file gets `Read-only file system` instead of an edit the next sync would
  lose, and the copy outlives a recreate: only what changed is sent again.

  Root in the VM could mount it writable again. That is no way to your
  machine: nothing of the copy ever goes back, and the next sync puts what
  MWT sent there in place again. It keeps an agent from editing what it
  shouldn't by mistake; the VM itself is the boundary.

  `arrange/2` makes the layout match the shares: each one's folder made
  and shown, and those of folders no longer shared unmounted and removed.
  It runs before each sync, and is cheap when nothing changed. A test's
  stand-in for the VM (`MWTClient.Sandbox.Guest.local/1`), where nothing
  can be mounted, shows each copy with a symlink instead.
  """

  alias MWTClient.Sandbox.Guest

  @base "/work/.shares"

  @doc "Where the copies of all shares live in the VM."
  @spec base() :: Path.t()
  def base, do: @base

  @doc "The folder in the VM holding the copy of the shared folder `path`."
  @spec store(Path.t()) :: Path.t()
  def store(path), do: Path.join([@base, id(path), "files"])

  defp id(path),
    do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  # Runs as root in the VM. Arguments: how to show a copy (mount, or link
  # in a test's stand-in), the folder of the stores, then an ID and the
  # path it is shown at, for each share. A path where something is mounted
  # already is left as it is: a share can't be at a path the VM mounts
  # itself (`MWTClient.Sandbox.Shares`), so what is there is its copy. A
  # store no share names any more is unmounted (lazily: a shell sitting in
  # it doesn't keep it) and removed. Busybox's mount, mountpoint and umount
  # do too: a bind, then a remount read-only; paths are absolute, so no
  # `--` is needed, which busybox's don't all take.
  @arrange ~S"""
  set -u
  mode=$1 base=$2
  shift 2
  status=0 keep=/
  mkdir -p -- "$base" || exit 1
  while [ $# -ge 2 ]; do
    id=$1 at=$2
    shift 2
    keep="$keep$id/"
    store=$base/$id
    if ! mkdir -p -- "$store/files" || ! printf '%s\n' "$at" >"$store/at"; then
      status=1
      continue
    fi
    case $mode in
      mount)
        if ! mountpoint -q "$at" 2>/dev/null; then
          if ! { mkdir -p -- "$at" && mount --bind "$store/files" "$at"; }; then
            echo "$at couldn't be shown in the VM." >&2
            status=1
          elif ! mount -o remount,bind,ro "$at"; then
            umount "$at" 2>/dev/null
            echo "$at couldn't be made read-only, so it isn't shown." >&2
            status=1
          fi
        fi
        ;;
      link)
        if [ ! -L "$at" ]; then
          mkdir -p -- "$(dirname -- "$at")" && ln -s -- "$store/files" "$at" || status=1
        fi
        ;;
    esac
  done
  for store in "$base"/*; do
    [ -d "$store" ] || continue
    id=${store##*/}
    case $keep in */"$id"/*) continue ;; esac
    at=$(head -n 1 -- "$store/at" 2>/dev/null)
    if [ -n "$at" ]; then
      case $mode in
        mount)
          if mountpoint -q "$at" 2>/dev/null && ! umount -l "$at"; then
            echo "$at couldn't be unmounted." >&2
            status=1
            continue
          fi
          rmdir -- "$at" 2>/dev/null
          ;;
        link) [ -L "$at" ] && rm -f -- "$at" ;;
      esac
    fi
    rm -rf -- "$store"
  done
  exit $status
  """

  @doc """
  Makes the VM behind `guest` hold a store for each of `paths`, the shared
  folders, shown read-only at its path, and nothing for folders no longer
  shared.
  """
  @spec arrange(Guest.t(), [Path.t()]) :: :ok | {:error, String.t()}
  def arrange(guest, paths) do
    pairs = Enum.flat_map(paths, &[id(&1), guest.place.(&1)])
    mode = Map.get(guest, :show, :mount) |> Atom.to_string()

    case guest.exec.(["sh", "-c", @arrange, "mwt-shares", mode, guest.place.(@base) | pairs]) do
      {:ok, _output} -> :ok
      {:error, text} -> {:error, "The shared folders couldn't be shown in the VM: " <> text}
    end
  end
end
