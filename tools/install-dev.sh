#!/bin/bash
# newest dev build onto the iphone 5, nothing else gets it. build first: DEV=1 tools/build-app.sh
# replaces the normal app. back: dpkg -r com.aronsz26.wa4s-dev, then dpkg -i the normal .deb
set -euo pipefail
cd "$(dirname "$0")/.."
ISH=${ISH:-$HOME/.ish5}
DEB=$(ls -t packages/com.aronsz26.wa4s-dev_*.deb | head -1)
D=/var/mobile/Library/WA4S
# postinst touches these when a respring is needed
MARKS="ls -l $D/.infosig-installed $D/.icon-installed.png $D/.callscreen-loaded.dylib 2>/dev/null; true"
BEFORE=$("$ISH" "$MARKS")
"$ISH" 'mkdir -p /var/root/debs; cat > /var/root/debs/wa-dev.deb' < "$DEB"
# no tail/head here, a broken pipe stops dpkg halfway
"$ISH" 'dpkg -i /var/root/debs/wa-dev.deb > /var/root/debs/wa-dev.log 2>&1; rc=$?; cat /var/root/debs/wa-dev.log; rm -f /var/root/debs/wa-dev.deb; exit $rc'
"$ISH" 'dpkg -l | grep com.aronsz26.wa4s'
if [ "$BEFORE" != "$("$ISH" "$MARKS")" ]; then
  echo "respring (name, icon or tweak changed), sblaunch works again after ~30 s"
  "$ISH" 'killall -9 SpringBoard' || true
  exit 0
fi
# dpkg leaves the old binary running if uicache didn't kill it, and a voip app stays down after an update until it's opened
"$ISH" 'killall -9 WA4S; true'
sleep 2
"$ISH" 'sblaunch com.aronsz26.wa4s' || echo "not started, phone is locked probably"
