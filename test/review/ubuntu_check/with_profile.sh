#!/usr/bin/env bash
# Runs in the Ubuntu VM after inside.sh failed: installs an AppArmor profile
# and runs the same check again.
#
#     with_profile.sh WORK own-bwrap     a copy of bwrap at /opt/mwt/bwrap, with a profile of its own
#     with_profile.sh WORK launcher      a profile on the program that starts everything, bwrap as it comes
set -u
WORK=$1
HOW=$2
export HOME="$WORK/home" MSB_HOME="$WORK/home" MSB_PATH="$WORK/runtime/bin/msb" NO_COLOR=1
sudo mkdir -p /opt/mwt

case "$HOW" in
  own-bwrap)
    sudo cp /usr/bin/bwrap /opt/mwt/bwrap
    sudo tee /etc/apparmor.d/mwt-bwrap > /dev/null <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>

profile mwt-bwrap /opt/mwt/bwrap flags=(unconfined) {
  userns,
  include if exists <local/mwt-bwrap>
}
PROFILE
    sudo apparmor_parser -r /etc/apparmor.d/mwt-bwrap && echo "profile mwt-bwrap loaded"
    MWT_BWRAP=/opt/mwt/bwrap python3 "$WORK/msb_confine/relay_live.py" --work "$WORK" --mib 128 2>&1 | tail -40
    ;;
  launcher)
    # Stands in for MWT's own program: everything it starts keeps its profile.
    sudo cp /usr/bin/env /opt/mwt/launcher
    sudo tee /etc/apparmor.d/mwt-launcher > /dev/null <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>

profile mwt-launcher /opt/mwt/launcher flags=(unconfined) {
  userns,
  include if exists <local/mwt-launcher>
}
PROFILE
    sudo apparmor_parser -r /etc/apparmor.d/mwt-launcher && echo "profile mwt-launcher loaded"
    /opt/mwt/launcher python3 "$WORK/msb_confine/relay_live.py" --work "$WORK" --mib 128 2>&1 | tail -40
    ;;
esac
