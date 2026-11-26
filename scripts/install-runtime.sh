#!/usr/bin/env bash
# Puts MWT's runtime into this checkout's priv/microsandbox, for
# `mix test --only vm` and for running a real VM from this checkout's MWT:
#
#   - msb and libkrunfw from a build kept in a cache every checkout shares
#     (MWT_RUNTIME_CACHE, /work/mwt-runtime by default: the agent sandbox's
#     Work disk), one per version, so checkouts that pin different ones
#     don't rebuild over each other. Built once, in a few minutes, with
#     build-microsandbox.sh;
#   - the relay and the presentations built from this checkout
#     (build-relay.sh, build-present.sh), since their
#     source can differ from one branch to the next. They take seconds.
#
# Meant for the agent sandbox's worktree slots, where VMs run only with VMs
# inside the VM turned on (/dev/kvm). On your machine, build-microsandbox.sh
# build-relay.sh and build-present.sh do the same into priv/microsandbox directly.
set -Eeuo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/install-runtime.sh\n'
  printf "Install msb (built once into MWT_RUNTIME_CACHE) and this checkout's relay into priv/microsandbox.\n"
  exit 0
fi
[[ $# -eq 0 ]] || { printf 'No arguments. Use --help for usage.\n' >&2; exit 1; }

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cache=${MWT_RUNTIME_CACHE:-/work/mwt-runtime}
out=$root/priv/microsandbox

# The version build-microsandbox.sh writes to VERSION: its UPSTREAM release
# and the first 9 characters of its REVISION.
pinned() { sed -n "s/^$1=\(.*\)$/\1/p" "$root/scripts/build-microsandbox.sh" | head -1; }
revision=$(pinned REVISION)
want=$(pinned UPSTREAM)+${revision:0:9}

built=$cache/runtimes/$want
if [[ $(cat "$built/VERSION" 2>/dev/null) != "$want" ]]; then
  printf '==> building msb %s into %s\n' "$want" "$built"
  MWT_MSB_SOURCE=$cache/src/$revision \
    MWT_MSB_DOWNLOADS=$cache/downloads \
    CARGO_TARGET_DIR=$cache/target \
    "$root/scripts/build-microsandbox.sh" "$built"
fi

printf '==> msb %s into %s\n' "$want" "$out"
rm -rf -- "$out"
mkdir -p -- "$out"
cp -a -- "$built/." "$out/"

"$root/scripts/build-relay.sh" "$out"
"$root/scripts/build-present.sh" "$out"
