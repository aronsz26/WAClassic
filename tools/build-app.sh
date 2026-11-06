#!/bin/bash
# builds WA4S.app (armv7, ios 6) on debian-home -> packages/*.deb
# IOS4=1 for the 3gs build (com.aronsz26.wa4s-ios4)
# DEV=1 for the dev build, iphone 5 only (com.aronsz26.wa4s-dev, see tools/install-dev.sh)
# toolchain: ios-clang + 9.3 sdk + ldid, same as encore/untisfix
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${BUILD_HOST:-debian-home}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' app/Resources/Info.plist)
ssh "$HOST" 'rm -rf ~/builds/WA4S && mkdir -p ~/builds/WA4S'
scp -q -r app tools/package-app.sh "$HOST":builds/WA4S/
IOS4=${IOS4:-0}
DEV=${DEV:-0}
PKG=com.aronsz26.wa4s
[ "$IOS4" = 1 ] && PKG=com.aronsz26.wa4s-ios4
DEBVER=$VERSION
DEVENV=
if [ "$DEV" = 1 ]; then
  [ "$IOS4" = 1 ] && { echo "dev builds are ios 6 only"; exit 1; }
  # build number = commits, + when the tree has changes
  BUILD=$(git rev-list --count HEAD)
  COMMIT=$(git rev-parse --short HEAD)
  [ -n "$(git status --porcelain -- app tools)" ] && BUILD="$BUILD+"
  PKG=com.aronsz26.wa4s-dev
  DEBVER="$VERSION+dev${BUILD%+}"
  DEVENV="DEV=1 DEV_BUILD='$BUILD' DEV_COMMIT='$COMMIT' DEV_DATE='$(date '+%d.%m.%Y %H:%M')'"
fi
ssh "$HOST" "cd ~/builds/WA4S && IOS4=$IOS4 $DEVENV bash package-app.sh '$VERSION'"
mkdir -p packages
scp -q "$HOST":builds/WA4S/${PKG}_${DEBVER}_iphoneos-arm.deb packages/
echo "packages/${PKG}_${DEBVER}_iphoneos-arm.deb"
