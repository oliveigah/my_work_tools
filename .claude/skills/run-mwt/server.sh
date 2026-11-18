#!/usr/bin/env bash
# Runs the MWT Phoenix dev server for driving it headlessly, on its own port
# and with its own data directory, so it never touches ~/.mwt_client or the
# installed app.
#
#   server.sh start [--fresh]   start and wait until it serves (--fresh wipes the data)
#   server.sh stop              stop it
#   server.sh status            say whether it is up
#
# PORT (default 4100) and MWT_RUN_DIR (default /tmp/mwt-run, no spaces) override.
set -euo pipefail

PORT="${PORT:-4100}"
RUN_DIR="${MWT_RUN_DIR:-/tmp/mwt-run}"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
URL="http://127.0.0.1:$PORT"

listening() { ss -ltn "sport = :$PORT" | grep -q LISTEN; }

case "${1:-}" in
  start)
    if listening; then
      echo "port $PORT is already in use; stop it first or pick another PORT" >&2
      exit 1
    fi

    if [ "${2:-}" = "--fresh" ]; then rm -rf "$RUN_DIR/data"; fi
    mkdir -p "$RUN_DIR"

    # The data directory is only configurable as application env, so it is
    # set as an Erlang flag; the value must be a binary, not a charlist.
    cd "$APP_DIR"
    PORT="$PORT" nohup elixir --erl "-mwt_client data_dir <<\"$RUN_DIR/data\">>" \
      -S mix phx.server >"$RUN_DIR/server.log" 2>&1 &

    if ! timeout 180 bash -c "until curl -sf -o /dev/null $URL/; do sleep 1; done"; then
      echo "server did not come up; last lines of $RUN_DIR/server.log:" >&2
      tail -30 "$RUN_DIR/server.log" >&2
      exit 1
    fi

    echo "up: $URL  data: $RUN_DIR/data  log: $RUN_DIR/server.log"
    ;;

  stop)
    # ss rather than lsof: iproute2 is everywhere this runs, lsof isn't.
    ss -ltnpH "sport = :$PORT" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u | xargs -r kill
    timeout 15 bash -c "while ss -ltn 'sport = :$PORT' | grep -q LISTEN; do sleep 0.2; done"
    echo "stopped"
    ;;

  status)
    if listening; then echo "up: $URL"; else echo "down"; fi
    ;;

  *)
    sed -n '2,10p' "$0" >&2
    exit 2
    ;;
esac
