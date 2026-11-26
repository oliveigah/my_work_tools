#!/usr/bin/env bash
# Builds the microsandbox runtime MWT ships with: msb from the upstream
# release commit pinned in scripts/microsandbox.pin
# (superradcompany/microsandbox), and that release's libkrunfw. Everything
# is pinned there, so every MWT build carries the same runtime; `mix
# microsandbox.update VERSION` moves the pin.
#
# Output (default priv/microsandbox, which the release copies along):
#   bin/msb                 the CLI, guest agent embedded
#   lib/$LIBKRUNFW          the guest kernel; msb finds it beside bin/
#   VERSION                 what --version prints: a build that differs is stale
#
# Needs git, curl, sha256sum, a C compiler and Rust/Cargo (strace too, for two
# of the filesystem tests). Downloads go through checksums; the source must be
# the pinned commit, with no local changes.
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-microsandbox.sh [OUTPUT_DIR | --version]\n'
  printf "Build msb from the pinned upstream release commit, and libkrunfw. Default output: priv/microsandbox\n"
  printf '%s\n' '--version prints the runtime version the pin builds, and builds nothing.'
  printf 'Env: MWT_MSB_SOURCE, MWT_MSB_DOWNLOADS, CARGO_TARGET_DIR, MWT_MSB_SKIP_TESTS=1\n'
  exit 0
fi
[[ $# -le 1 ]] || { printf 'At most one argument. Use --help for usage.\n' >&2; exit 1; }

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=microsandbox.pin
source "$project/scripts/microsandbox.pin"
# This runtime's identity, written to VERSION: the release, and the first 9
# characters of the commit it was built from.
VERSION=$UPSTREAM+${REVISION:0:9}
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' "$VERSION"
  exit 0
fi
[[ $(uname -s) == Linux ]] || { printf 'This build targets Linux.\n' >&2; exit 1; }

case $(uname -m) in
  x86_64)
    ARCH=x86_64
    AGENTD_SHA256=$AGENTD_SHA256_X86_64
    LIBKRUNFW_SHA256=$LIBKRUNFW_SHA256_X86_64
    ;;
  aarch64)
    ARCH=aarch64
    AGENTD_SHA256=$AGENTD_SHA256_AARCH64
    LIBKRUNFW_SHA256=$LIBKRUNFW_SHA256_AARCH64
    ;;
  *) printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
RELEASE=${REPOSITORY%.git}/releases/download/v$UPSTREAM

output=${1:-$project/priv/microsandbox}
# MWT_MSB_SOURCE may name an existing checkout (a clone of microsandbox); it
# must be at REVISION with no local changes, and is never modified.
source=${MWT_MSB_SOURCE:-$project/tmp/microsandbox-src/$REVISION}
downloads=${MWT_MSB_DOWNLOADS:-$project/tmp/microsandbox-downloads}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$project/tmp/microsandbox-target}

for tool in git curl sha256sum cc cargo; do
  command -v "$tool" >/dev/null || { printf 'Missing build tool: %s\n' "$tool" >&2; exit 1; }
done

# fetch NAME SHA256: the release asset NAME in $downloads, checked.
fetch() {
  local name=$1 sha256=$2 file=$downloads/$UPSTREAM/$1
  if [[ ! -f "$file" ]] || ! printf '%s  %s\n' "$sha256" "$file" | sha256sum --check --status; then
    mkdir -p -- "$(dirname -- "$file")"
    curl --fail --location --silent --show-error --proto '=https' \
      --retry 5 --retry-delay 2 --output "$file.part" "$RELEASE/$name"
    printf '%s  %s\n' "$sha256" "$file.part" | sha256sum --check --strict --quiet
    mv -f -- "$file.part" "$file"
  fi
  printf '%s\n' "$file"
}

printf '==> microsandbox %s source (%s)\n' "$VERSION" "$REPOSITORY"
if [[ ! -d "$source" ]]; then
  # Only this one commit, fetched by hash; GitHub serves any pushed commit.
  partial=$source.partial
  rm -rf -- "$partial"
  mkdir -p -- "$partial"
  git -C "$partial" init --quiet
  git -C "$partial" fetch --quiet --depth 1 "$REPOSITORY" "$REVISION"
  git -C "$partial" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
  mv -- "$partial" "$source"
fi
if [[ $(git -C "$source" rev-parse HEAD) != "$REVISION" ]]; then
  printf 'Expected %s at %s; refusing to build another commit.\n' "$source" "$REVISION" >&2
  exit 1
fi
if [[ -n $(git -C "$source" status --porcelain --untracked-files=no) ]]; then
  printf '%s has local changes; refusing to build anything but %s.\n' "$source" "$REVISION" >&2
  exit 1
fi
# The pin says what this commit builds with; a pin that doesn't is wrong.
libkrun=$(awk '$0 == "name = \"msb_krun\"" { getline v; getline s; print v; print s; exit }' "$source/Cargo.lock" |
  sed -n 's/^\(version\|source\) = "\(.*\)"$/\2/p' | paste -sd ' ')
if [[ "$libkrun" != "$LIBKRUN_VERSION $LIBKRUN_SOURCE" ]]; then
  printf 'The pin says libkrun %s from %s; %s/Cargo.lock says %s.\n' \
    "$LIBKRUN_VERSION" "$LIBKRUN_SOURCE" "$source" "${libkrun:-nothing}" >&2
  exit 1
fi
kernel=$(git -C "$source" rev-parse HEAD:vendor/libkrunfw)
if [[ "$kernel" != "$KERNEL" ]]; then
  printf 'The pin says the kernel is vendor/libkrunfw at %s; %s has %s.\n' "$KERNEL" "$REVISION" "$kernel" >&2
  exit 1
fi
if ! grep -q "LIBKRUNFW_VERSION: &str = \"${LIBKRUNFW#libkrunfw.so.}\"" "$source/crates/utils/lib/lib.rs"; then
  printf 'The pin says msb looks for %s; crates/utils/lib/lib.rs says otherwise.\n' "$LIBKRUNFW" >&2
  exit 1
fi

printf '==> release artifacts\n'
agentd=$(fetch "agentd-$ARCH" "$AGENTD_SHA256")
libkrunfw=$(fetch "libkrunfw-linux-$ARCH.so" "$LIBKRUNFW_SHA256")

# The guest agent is embedded from here; building never downloads or
# installs anything into a microsandbox home.
export MSB_EMBED_ARTIFACTS_DIR=$downloads/$UPSTREAM/embed
mkdir -p -- "$MSB_EMBED_ARTIFACTS_DIR"
install -m 755 -- "$agentd" "$MSB_EMBED_ARTIFACTS_DIR/agentd"
export CARGO_INCREMENTAL=0

cd -- "$source"
if [[ ${MWT_MSB_SKIP_TESTS:-} != 1 ]]; then
  printf '==> filesystem tests\n'
  # Two close-error tests trace the process with strace; without it they
  # fail on setup, so they are skipped rather than failing the build.
  skip=()
  if ! command -v strace >/dev/null; then
    printf 'strace not found: skipping the two close-error tests that need it\n'
    skip=(--skip test_create_write_close_budget --skip test_flush_reports_backing_close_errors_by_default)
  fi
  cargo test --locked --no-default-features --features embed-binaries -p microsandbox-filesystem --lib -- "${skip[@]}"
fi

printf '==> building msb\n'
# Release optimizations without whole-program LTO, which costs a lot of memory.
CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
  cargo build --locked --release --no-default-features \
  --features embed-binaries,net,ssh,keyring -p microsandbox-cli

mkdir -p -- "$(dirname -- "$output")"
staged=$(mktemp -d "$(dirname -- "$output")/.microsandbox.XXXXXX")
trap 'rm -rf -- "$staged"' EXIT
# mktemp makes it 0700; packaged under a root-owned folder, users must read it.
chmod 755 -- "$staged"
install -D -m 755 -- "$CARGO_TARGET_DIR/release/msb" "$staged/bin/msb"
install -D -m 644 -- "$libkrunfw" "$staged/lib/$LIBKRUNFW"
reported=$(MSB_HOME="$staged/home" "$staged/bin/msb" --version)
[[ "$reported" == "msb $UPSTREAM" ]] || { printf 'Built msb reports %q\n' "$reported" >&2; exit 1; }
rm -rf -- "$staged/home"
printf '%s\n' "$VERSION" > "$staged/VERSION"

rm -rf -- "$output"
mv -- "$staged" "$output"
trap - EXIT
printf '==> ready: %s (%s)\n' "$output" "$reported"
