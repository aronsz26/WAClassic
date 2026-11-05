#!/bin/bash
# builds WA4S.app (armv7, ios 6) on debian-home -> packages/*.deb
# IOS4=1 for the 3gs build (com.aronsz26.wa4s-ios4)
# toolchain: ios-clang + 9.3 sdk + ldid, same as encore/untisfix
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${BUILD_HOST:-debian-home}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' app/Resources/Info.plist)
ssh "$HOST" 'rm -rf ~/builds/WA4S && mkdir -p ~/builds/WA4S'
scp -q -r app tools/package-app.sh "$HOST":builds/WA4S/
IOS4=${IOS4:-0}
PKG=com.aronsz26.wa4s
[ "$IOS4" = 1 ] && PKG=com.aronsz26.wa4s-ios4
ssh "$HOST" "cd ~/builds/WA4S && IOS4=$IOS4 bash package-app.sh '$VERSION'"
mkdir -p packages
scp -q "$HOST":builds/WA4S/${PKG}_${VERSION}_iphoneos-arm.deb packages/
echo "packages/${PKG}_${VERSION}_iphoneos-arm.deb"
