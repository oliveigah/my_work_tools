#!/usr/bin/env bash
# Builds SQLite3 Multiple Ciphers, SQLite with page-level encryption, as the
# static library exqlite links in place of its own SQLite (docs/architecture.md):
#
#   OUTPUT_DIR/libsqlite3mc.a
#   OUTPUT_DIR/include/sqlite3.h, sqlite3ext.h, sqlite3mc_amalgamation.h
#
# It downloads the amalgamation of the release VERSION (bundling SQLite
# SQLITE_VERSION), refuses it unless its SHA-256 is SHA256, and compiles it
# with the C compiler. mix.exs runs it, with the versions it pins, when the
# library is missing. The result needs only libc and libm, and exports no
# SQLite symbol from exqlite's NIF.
#
# Built aside and moved into place, so a build stopped halfway, or two at
# once, never leave half a library behind.
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-sqlite3mc.sh VERSION SQLITE_VERSION SHA256 OUTPUT_DIR\n'
  printf 'Build SQLite3 Multiple Ciphers VERSION into OUTPUT_DIR.\n'
  exit 0
fi
[[ $# -eq 4 ]] || { printf 'Four arguments expected. Use --help for usage.\n' >&2; exit 1; }

version=$1
sqlite=$2
sha256=$3
out=$4
name="sqlite3mc-${version}-sqlite-${sqlite}-amalgamation.zip"
url="https://github.com/utelle/SQLite3MultipleCiphers/releases/download/v${version}/${name}"

mkdir -p "$(dirname -- "$out")"
work=$(mktemp -d "${out}.building.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

printf 'Building SQLite3 Multiple Ciphers %s (SQLite %s), once, in under a minute\n' "$version" "$sqlite"

curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --retry 3 --retry-delay 2 --output "$work/$name" "$url"
printf '%s  %s\n' "$sha256" "$work/$name" | sha256sum --check --strict --quiet

# Erlang is wherever MWT builds; unzip and Python may not be. ERL is the
# one running mix, which mix.exs passes, since a version manager's shim may
# not know which to run outside the project.
mkdir "$work/src"
"${ERL:-erl}" -noshell -eval '
  [Zip, Dir] = init:get_plain_arguments(),
  case zip:extract(Zip, [{cwd, Dir}]) of
    {ok, _Files} -> halt(0);
    Error -> io:format(standard_error, "could not unzip ~ts: ~p~n", [Zip, Error]), halt(1)
  end.' -extra "$work/$name" "$work/src"

mkdir -p "$work/out/include"
# The options exqlite builds its own SQLite with, less the extensions MWT
# doesn't use, plus the dbstat table the Storage page reads sizes from.
# Temporary tables in memory unless a connection asks for a file, and
# temporary files encrypted: the release's own defaults, pinned so a later
# one can't change them under MWT (Compact relies on both).
cc -c -fPIC -O2 -fvisibility=hidden -DNDEBUG=1 \
  -DSQLITE_TEMP_STORE=2 -DSQLITE3MC_ENCRYPT_TEMP_FILES=1 \
  -DSQLITE_THREADSAFE=1 -DSQLITE_USE_URI=1 -DSQLITE_DQS=0 \
  -DSQLITE_LIKE_DOESNT_MATCH_BLOBS=1 -DHAVE_USLEEP=1 \
  -DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1 \
  -DSQLITE_ENABLE_MATH_FUNCTIONS=1 -DSQLITE_OMIT_DEPRECATED=1 \
  "$work/src/sqlite3mc_amalgamation.c" -o "$work/sqlite3mc.o"
ar rcs "$work/out/libsqlite3mc.a" "$work/sqlite3mc.o"
cp "$work/src/sqlite3.h" "$work/src/sqlite3ext.h" "$work/src/sqlite3mc_amalgamation.h" "$work/out/include/"

# Another build may have finished first: its library is as good as this one.
if ! mv -T -- "$work/out" "$out" 2>/dev/null; then
  [[ -f "$out/libsqlite3mc.a" ]] || {
    printf '%s is in the way: remove it and build again.\n' "$out" >&2
    exit 1
  }
fi
printf 'Built %s\n' "$out/libsqlite3mc.a"
