# shellcheck shell=sh
# Written by MWT, read by every bash in the VM (through BASH_ENV and
# /etc/profile.d). Login shells reset PATH; restore the tools for Zed's
# environment probe, terminals, language servers, tasks and agents alike.
# Keep this POSIX compatible: /etc/profile can also be read by sh.
# /mnt/mwt/bin holds `mwt`, which agents ask MWT for access with.
for _mwt_bin in /mnt/mwt/bin /usr/local/share/cargo/bin "$HOME/.local/bin" \
  /cache/go/bin /cache/cargo/bin /cache/npm-global/bin \
  /usr/local/share/mise/shims /cache/mise/shims; do
  case ":$PATH:" in
    *:"$_mwt_bin":*) ;;
    *) PATH="$_mwt_bin:$PATH" ;;
  esac
done
unset _mwt_bin
export PATH

# Host writes to shared folders do not emit inotify events in the VM. Zed
# excludes virtiofs from automatic polling, so choose polling explicitly.
export ZED_FILE_WATCHER_MODE=poll
export ZED_FILE_WATCHER_POLL_MS=5000

# Credentials are supplied only by `mwt exec CREDENTIAL -- COMMAND`. Exporting
# them here would also make editors and public downloaders authenticate.
