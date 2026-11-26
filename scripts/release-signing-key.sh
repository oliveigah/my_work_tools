#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/release-signing-key.sh [PRIVATE_KEY_FILE]\n'
  printf 'Make the Ed25519 key that signs releases: the public half goes to\n'
  printf 'priv/release_signing_key.pub, the private half to PRIVATE_KEY_FILE\n'
  printf '(default ~/.config/mwt/release-signing-key.pem), never overwritten.\n'
  printf 'Run it on your own machine. See Releases in README.md.\n'
  exit 0
fi
[[ $# -le 1 ]] || { printf 'At most one argument. Use --help for usage.\n' >&2; exit 1; }

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
public="$project_dir/priv/release_signing_key.pub"
private="${1:-$HOME/.config/mwt/release-signing-key.pem}"

command -v openssl >/dev/null || { printf 'openssl is required.\n' >&2; exit 1; }
[[ ! -e "$private" ]] || { printf '%s exists already; not replacing it.\n' "$private" >&2; exit 1; }

umask 077
mkdir -p -- "$(dirname -- "$private")"
openssl genpkey -algorithm ed25519 -out "$private"
openssl pkey -in "$private" -pubout -out "$public"
chmod 644 -- "$public"

cat <<EOF
Private key: $private
Public key:  $public (commit it)

Next, give the private key to the release workflow, then keep it offline:

  gh secret set RELEASE_SIGNING_KEY --repo oliveigah/my_work_tools < "$private"
EOF
