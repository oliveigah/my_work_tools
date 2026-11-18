#!/bin/sh
# Runs as root after MWT's deb is removed: takes away what postinst.sh made.
set -e

case "${1:-}" in
  remove | purge)
    if [ -e /etc/apparmor.d/mwt-bwrap ]; then
      if command -v apparmor_parser > /dev/null 2>&1; then
        apparmor_parser --remove /etc/apparmor.d/mwt-bwrap 2> /dev/null || true
      fi
      rm -f /etc/apparmor.d/mwt-bwrap
    fi
    rm -f /usr/lib/mwt/bwrap
    rmdir /usr/lib/mwt 2> /dev/null || true
    ;;
esac

exit 0
