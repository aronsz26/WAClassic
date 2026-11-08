#!/bin/bash
# newest dev build onto test phones. build first: DEV=1 tools/build-app.sh, IOS4=1 DEV=1 for 4s and 3gs
# tools/install-dev.sh [5|4s|3gs|all], default 5
# replaces the normal app. back: dpkg -r com.aronsz26.wa4s-dev (or -dev-ios4), then dpkg -i the normal .deb
set -euo pipefail
cd "$(dirname "$0")/.."
D=/var/mobile/Library/WA4S
# postinst touches these when a respring is needed
MARKS="ls -l $D/.infosig-installed $D/.icon-installed.png $D/.callscreen-loaded.dylib 2>/dev/null; true"

install_on() {
  local ISH=$1 PKG=$2 DEB BEFORE
  DEB=$(ls -t packages/${PKG}_*.deb | head -1)
  echo "== $ISH: $DEB"
  BEFORE=$("$ISH" "$MARKS")
  # prefs stay, but keep a copy from before the first dev build
  "$ISH" 'P=/var/mobile/Library/Preferences/com.aronsz26.wa4s.plist; [ -f $P.bak-vor-dev ] || cp -p $P $P.bak-vor-dev; true'
  "$ISH" 'mkdir -p /var/root/debs; cat > /var/root/debs/wa-dev.deb' < "$DEB"
  # no tail/head here, a broken pipe stops dpkg halfway
  "$ISH" 'dpkg -i /var/root/debs/wa-dev.deb > /var/root/debs/wa-dev.log 2>&1; rc=$?; cat /var/root/debs/wa-dev.log; rm -f /var/root/debs/wa-dev.deb; exit $rc'
  "$ISH" 'dpkg -l | grep com.aronsz26.wa4s'
  if [ "$BEFORE" != "$("$ISH" "$MARKS")" ]; then
    echo "respring (name, icon or tweak changed), phones with a passcode need unlocking after"
    "$ISH" 'killall -9 SpringBoard' || true
    return 0
  fi
  # dpkg leaves the old binary running if uicache didn't kill it, and a voip app stays down after an update until it's opened
  "$ISH" 'killall -9 WA4S; true'
  sleep 2
  "$ISH" 'uiopen wadev:' || echo "not started, phone is locked probably"
}

case "${1:-5}" in
  5) install_on "${ISH:-$HOME/.ish5}" com.aronsz26.wa4s-dev ;;
  4s) install_on "$HOME/.ish4s" com.aronsz26.wa4s-dev-ios4 ;;
  3gs) install_on "$HOME/.ish3gs" com.aronsz26.wa4s-dev-ios4 ;;
  all)
    install_on "$HOME/.ish5" com.aronsz26.wa4s-dev
    install_on "$HOME/.ish4s" com.aronsz26.wa4s-dev-ios4
    install_on "$HOME/.ish3gs" com.aronsz26.wa4s-dev-ios4
    ;;
  *) echo "usage: $0 [5|4s|3gs|all]"; exit 1 ;;
esac
