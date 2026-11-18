#!/usr/bin/env bash
# Builds MWT's ACP shell (native/mwt_acp), which runs in the agent sandbox's
# VM, into the runtime folder, beside msb and the relay:
#
#   bin/mwt-acp
#
# MWT hands it to the VM through the inbox (/mnt/mwt/bin/mwt-acp). The VM's
# image is yours, so the shell is linked statically (musl) and runs on any
# Linux of the same architecture. It has no dependencies: the build needs
# Rust/Cargo with the musl target, and no network. `mix compile` runs it
# when native/mwt_acp changed (Mix.Tasks.Compile.Native).
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-acp.sh [OUTPUT_DIR]\n'
  printf 'Build mwt-acp into OUTPUT_DIR/bin. Default output: priv/microsandbox\n'
  exit 0
fi
[[ $# -le 1 ]] || { printf 'At most one argument. Use --help for usage.\n' >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { printf 'This build targets Linux.\n' >&2; exit 1; }

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-$root/priv/microsandbox}
target=$(uname -m)-unknown-linux-musl

if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx "$target"; then
  printf 'The Rust target %s is missing. Add it once with:\n  rustup target add %s\n' "$target" "$target" >&2
  exit 1
fi

cargo build --release --locked --offline --target "$target" --manifest-path "$root/native/mwt_acp/Cargo.toml"
install -D -m 0755 "$root/native/mwt_acp/target/$target/release/mwt-acp" "$out/bin/mwt-acp"
printf 'Built %s\n' "$out/bin/mwt-acp"
