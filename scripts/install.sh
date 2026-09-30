#!/bin/sh
# Builds the .deb and installs it on a jailbroken device over SSH.
#
#   IPAD=192.168.1.50 scripts/install.sh      # ssh root@192.168.1.50
#   scripts/install.sh                        # host "ipad" from .local/ssh/config
#   FINALPACKAGE=1 scripts/install.sh         # release build
set -eu
cd "$(dirname "$0")/.."

if [ -n "${IPAD:-}" ]; then
    ssh_config=""
    host="root@$IPAD"
elif [ -f .local/ssh/config ]; then
    ssh_config="-F .local/ssh/config"
    host="ipad"
else
    echo "Set IPAD to the device's IP address (or add a Host named ipad to .local/ssh/config)." >&2
    exit 1
fi

rm -f packages/*.deb
make package FINALPACKAGE="${FINALPACKAGE:-0}"
deb=$(ls packages/*.deb)

# $ssh_config is deliberately unquoted: it's either empty or two words.
scp $ssh_config "$deb" "$host:/tmp/legacydisplay.deb"
# uicache registers the app with SpringBoard so the icon appears without a respring.
ssh $ssh_config "$host" 'dpkg -i /tmp/legacydisplay.deb && rm /tmp/legacydisplay.deb && uicache -p /Applications/LegacyDisplay.app'
echo "Installed $(basename "$deb")"
