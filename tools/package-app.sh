#!/bin/bash
# runs on the build host: compile, link, sign, pack
set -euo pipefail
VERSION=$1
IOS4=${IOS4:-0} # 1: the iPhone 3GS build (iOS 4.3, with app/ios4's ARC runtime and iOS 5/6 replacements)
DEV=${DEV:-0} # 1: dev build with app/dev, same bundle id and data folder as the normal app
SDK=$HOME/builds/sdk/iPhoneOS9.3-armv7.sdk
CC=$HOME/toolchains/bin/ios-clang
LDID=$HOME/theos/toolchain/linux/iphone/bin/ldid
TARGET=armv7-apple-ios6.0 PKG=com.aronsz26.wa4s MINOS=6.0
NAME="WA Classic" DEPENDS="firmware (>= 6.0), mobilesubstrate" OTHER=com.aronsz26.wa4s-ios4
# say sdk 9.3, otherwise ios 7-9 show the app in ios 6 style (ios 6 doesn't care)
SDKVERSION=(-Wl,-sdk_version,9.3)
FLAGS=(-target $TARGET -isysroot "$SDK" -O2 -g0 -fobjc-arc -Wall -Wno-unguarded-availability
       -Wno-deprecated-declarations -Wno-unused-command-line-argument)
if [ "$IOS4" = 1 ]; then
  TARGET=armv7-apple-ios4.3 PKG=com.aronsz26.wa4s-ios4 MINOS=4.3
  NAME="WA Classic for iOS 4 and 5" DEPENDS="firmware (>= 4.3), firmware (<< 6.0), mobilesubstrate" OTHER=com.aronsz26.wa4s
  FLAGS=(-target $TARGET -isysroot "$SDK" -O2 -g0 -fobjc-arc -Wall -Wno-unguarded-availability
         -Wno-deprecated-declarations -Wno-unused-command-line-argument
         -DWA_IOS4=1 -Xclang -fobjc-runtime-has-weak -include app/ios4/WAIOS4Prefix.h)
  SDKVERSION=()
fi
DEBVER=$VERSION
if [ "$DEV" = 1 ]; then
  PKG=com.aronsz26.wa4s-dev NAME="WA Classic Dev" OTHER="com.aronsz26.wa4s, com.aronsz26.wa4s-ios4"
  DEBVER="$VERSION+dev${DEV_BUILD%+}"
  FLAGS+=(-DWA_DEV=1 "-DWA_DEV_BUILD=\"$DEV_BUILD\"" "-DWA_DEV_COMMIT=\"$DEV_COMMIT\"" "-DWA_DEV_DATE=\"$DEV_DATE\"")
fi
rm -rf obj && mkdir -p obj
SOURCES=(app/*.m)
[ "$DEV" = 1 ] && SOURCES+=(app/dev/*.m)
for f in "${SOURCES[@]}"; do
  "$CC" "${FLAGS[@]}" -c "$f" -o "obj/$(basename "$f").o" 2>&1 | grep -v 'built for iOS Simulator' || true
  test -f "obj/$(basename "$f").o"
done
if [ "$IOS4" = 1 ]; then
  "$CC" "${FLAGS[@]}" -c app/ios4/WACompat4.m -o obj/WACompat4.m.o
  "$CC" "${FLAGS[@]}" -c app/ios4/WAJSON4.m -o obj/WAJSON4.m.o
  "$CC" "${FLAGS[@]/-fobjc-arc/-fno-objc-arc}" -c app/ios4/WAIOS4Runtime.m -o obj/WAIOS4Runtime.m.o
fi
# no -fobjc-arc when linking (no arclite). flat namespace + -U because the url classes
# are in CFNetwork in the 9.3 sdk but Foundation on ios 6
"$CC" -target $TARGET -isysroot "$SDK" -o WA4S obj/*.o \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -framework AVFoundation -framework AudioToolbox -framework Security -framework SystemConfiguration -framework CFNetwork -framework MediaPlayer -framework MobileCoreServices -framework CoreMedia -framework CoreVideo -framework ImageIO -framework CoreText -lobjc -Wl,-dead_strip \
  ${SDKVERSION[@]+"${SDKVERSION[@]}"} \
  -Wl,-flat_namespace -Wl,-U,_memcpy -Wl,-U,_memcmp -Wl,-U,_memmove -Wl,-U,_memset \
  -Wl,-U,'_OBJC_CLASS_$_NSHTTPURLResponse' -Wl,-U,'_OBJC_CLASS_$_NSMutableURLRequest' -Wl,-U,'_OBJC_CLASS_$_NSURLConnection' \
  -Wl,-U,'_OBJC_CLASS_$_NSURLRequest' -Wl,-U,'_OBJC_CLASS_$_NSURLResponse' -Wl,-U,'_OBJC_CLASS_$_NSURLCache' \
  2>&1 | grep -v 'built for iOS Simulator' || true
test -f WA4S
rm -rf layout && mkdir -p layout/Applications layout/DEBIAN
cp -r app/Resources layout/Applications/WA4S.app
if [ "$IOS4" = 1 ]; then
  plutil() { python3 -c "import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,'rb')); d['MinimumOSVersion']='4.3'; plistlib.dump(d,open(p,'wb'))" "$1"; }
  plutil layout/Applications/WA4S.app/Info.plist
fi
if [ "$DEV" = 1 ]; then
  python3 -c "import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,'rb')); d['CFBundleDisplayName']='WA Dev'; plistlib.dump(d,open(p,'wb'))" layout/Applications/WA4S.app/Info.plist
fi
cp WA4S layout/Applications/WA4S.app/WA4S
# info.plist without the version, so postinst only runs uicache when it really changed
python3 -c "import plistlib,sys,hashlib; d=plistlib.load(open(sys.argv[1],'rb')); [d.pop(k,None) for k in ('CFBundleVersion','CFBundleShortVersionString')]; print(hashlib.sha1(repr(sorted(d.items())).encode()).hexdigest())" layout/Applications/WA4S.app/Info.plist > layout/Applications/WA4S.app/.infosig
# no whatsapp files in the package, just placeholders the app fills in later
cp app/Launch/Default.png app/Launch/Default@2x.png app/Launch/Default-568h@2x.png layout/Applications/WA4S.app/
for f in Tri-tone.caf Ringtone.caf Xylophone.caf Bell.caf Boing.caf Glass.caf Harp.caf TimePassing.caf; do
  : > "layout/Applications/WA4S.app/$f"
done
"$LDID" -S layout/Applications/WA4S.app/WA4S
# callscreen tweak, no ARC. flat namespace because NSObject moved between libobjc/CF
TW=layout/Library/MobileSubstrate/DynamicLibraries
mkdir -p $TW
"$CC" -target armv7-apple-ios4.3 -isysroot "$SDK" -O2 -g0 -Wall -Wno-deprecated-declarations -Wno-unused-command-line-argument \
  -dynamiclib -install_name /Library/MobileSubstrate/DynamicLibraries/WACallScreen.dylib \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -lobjc \
  -Wl,-flat_namespace -Wl,-U,'_OBJC_CLASS_$_NSObject' -Wl,-U,'_OBJC_METACLASS_$_NSObject' \
  -o $TW/WACallScreen.dylib app/callscreen/WACallScreen.m 2>&1 | grep -v 'built for iOS Simulator' || true
test -f $TW/WACallScreen.dylib
"$LDID" -S $TW/WACallScreen.dylib
printf '{ Filter = { Bundles = ( "com.apple.springboard" ); }; }\n' > $TW/WACallScreen.plist
cat > layout/DEBIAN/control <<CTRL
Package: $PKG
Name: $NAME
Version: $DEBVER
Architecture: iphoneos-arm
Description: Unofficial WhatsApp client for iOS 4 to 6, through your own WA Classic bridge (linked device). Not affiliated with WhatsApp or Meta.
Maintainer: aronsz26
Author: aronsz26
Section: Social
Depends: $DEPENDS
Conflicts: $OTHER
Replaces: $OTHER
CTRL
cat > layout/DEBIAN/postinst <<'POST'
#!/bin/sh
# copy synced launch image/sounds back in (no symlinks), owned by mobile. icon stays ours
# app folder owned by mobile, otherwise no log/assets on a fresh install
mkdir -p /var/mobile/Library/WA4S && chown mobile:mobile /var/mobile/Library/WA4S
A=/var/mobile/Library/WA4S/Assets
for f in Default.png Default@2x.png Default-568h@2x.png Tri-tone.caf Ringtone.caf Xylophone.caf Bell.caf Boing.caf Glass.caf Harp.caf TimePassing.caf; do
  if [ -f "$A/$f" ] && [ ! -L "$A/$f" ]; then cat "$A/$f" > "/Applications/WA4S.app/$f"; fi
  chown mobile:mobile "/Applications/WA4S.app/$f"
  chmod 644 "/Applications/WA4S.app/$f"
done
# (old cmp crashes on ios 9, treat as changed)
same() { sh -c 'cmp -s "$1" "$2"; exit $?' sh "$1" "$2" 2>/dev/null; }
RESPRING=0
# icon cache only when the icon changed. ios 6 draws it square until a respring otherwise
I=/Applications/WA4S.app/Icon@2x.png IC=/var/mobile/Library/WA4S/.icon-installed.png
if ! same "$I" "$IC"; then
  rm -f /var/mobile/Library/Caches/com.apple.IconsCache/com.aronsz26.wa4s_*
  cp "$I" "$IC" && chown mobile:mobile "$IC"
  RESPRING=1
fi
# uicache wipes the whole icon cache on ios 6 (square icon until respring), so only when needed
S=/Applications/WA4S.app/.infosig SC=/var/mobile/Library/WA4S/.infosig-installed
if ! same "$S" "$SC"; then
  su mobile -c uicache 2>/dev/null || uicache 2>/dev/null || true
  cp "$S" "$SC" && chown mobile:mobile "$SC"
  RESPRING=1
fi
# respring if the tweak changed too
T=/Library/MobileSubstrate/DynamicLibraries/WACallScreen.dylib C=/var/mobile/Library/WA4S/.callscreen-loaded.dylib
if ! same "$T" "$C"; then
  cp "$T" "$C" && chown mobile:mobile "$C"
  RESPRING=1
fi
if [ "$RESPRING" = 1 ] && [ -n "$CYDIA" ]; then eval "echo 'finish:restart' >&${CYDIA%% *}"; fi
exit 0
POST
chmod 755 layout/DEBIAN/postinst layout/Applications/WA4S.app/WA4S
find layout -type d -exec chmod 755 {} +
dpkg-deb --root-owner-group -Zgzip -b layout "${PKG}_${DEBVER}_iphoneos-arm.deb" >/dev/null
echo "WA4S: $(stat -c %s WA4S) Byte"
