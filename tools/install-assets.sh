#!/bin/bash
# copy the 2.10 graphics + sounds from WhatsApp.app to the phone (device only, never in the repo)
# usage: tools/install-assets.sh ~/wa-legacy-ipa/extracted/Payload/WhatsApp.app
# DEVICE=~/.ish3gs for the 3gs (default 4s)
set -euo pipefail
APP=${1:?path to an extracted WhatsApp.app (2.10.x)}
DEV=${DEVICE:-$HOME/.ish4s}
NAMES=(GreenBubbleOut GrayBubbleIn mark_s mark_d GrayClockIcon ChatInputControlsBG ChatInputFieldBG SendButtonNormal
  SendButtonPressed ChatButtonNormal ChatButtonPressed MicBtn MicRecBtn MicRecRed MicRecGray MicOverlay Play PlayPressed
  Pause PausePressed UIScrubberKnob UIScrubberBlueFill UIScrubberBlueCap UIScrubberWhiteFill UIScrubberWhiteCap
  MicIncoming MicOutgoing MicBlueIncoming MicBlueSent MicChats MicChatsBlue EmptyContact GroupChat ThumbMask ThumbOverlay
  MuteIndicator Chats Settings "My status" NotificationBg NotificationBgSelected NotificationClose Poof Pen ArrowDown
  VideoOverlayPlay Download DownloadButtonBg CellDivider NoGroupMedia ProfilePicEditPhoto RedButton RedButtonPressed GroupIconFrameEdit TextFieldBg ProfilePicAddPhoto BoxShadow PayNowBtn NoFaves TT-LeftTop TT-CenterTop TT-RightTop TT-LeftMiddle TT-CenterMiddle TT-RightMiddle TT-LeftBottom TT-CenterBottom TT-ArrowBottom TT-RightBottom TT-Close BrdtChatListIcon BroadcastStatusIcon BrdtRebroadcast BroadcastBubbleOut BrdtCheck BrdtDoubleCheck BrdtAttachPanel BrdtAttachCamera BrdtAttachCameraPressed BrdtAttachGallery BrdtAttachGalleryPressed BrdtAttachedOverlay BrdtAttachmentRemove Default Default-568h Icon)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Assets"
for n in "${NAMES[@]}"; do
  for f in "$APP/$n.png" "$APP/$n@2x.png"; do [ -f "$f" ] && cp "$f" "$STAGE/Assets/"; done
done
cp "$APP"/*.caf "$STAGE/Assets/" 2>/dev/null || true
cp "$APP/PaymentWP@2x.jpg" "$STAGE/Assets/" # the setup's Welcome wallpaper (only a jpg, only @2x)
# wallpapers
cp -R "$APP/Wallpaper" "$STAGE/Assets/Wallpaper"
# ringtone: ring.m4r -> ima4 caf (no aac for notification sounds), max 30s
"$DEV" 'cat /System/Library/CoreServices/SpringBoard.app/ring.m4r' > "$STAGE/ring.m4r"
afconvert -f WAVE -d LEI16@22050 -c 1 "$STAGE/ring.m4r" "$STAGE/ring.wav"
python3 -I -c 'import sys, wave
src = wave.open(sys.argv[1]); params, frames = src.getparams(), src.readframes(src.getnframes())
times = max(1, int(29 * params.framerate / max(1, params.nframes)))
dst = wave.open(sys.argv[2], "wb"); dst.setparams(params); dst.writeframes(frames * times); dst.close()' "$STAGE/ring.wav" "$STAGE/ring3.wav"
afconvert -f caff -d ima4 "$STAGE/ring3.wav" "$STAGE/Assets/Ringtone.caf"
rm -f "$STAGE/ring.m4r" "$STAGE/ring.wav" "$STAGE/ring3.wav"
# icon: un-crush the CgBI png, bake in gloss + corners (ios 6 doesn't mask /Applications apps)
for f in Icon.png Icon@2x.png; do
  [ -f "$STAGE/Assets/$f" ] || continue
  sips -s format png "$STAGE/Assets/$f" --out "$STAGE/plain.png" >/dev/null
  uv run --quiet --with pillow --with numpy python3 -I "$(dirname "$0")/gloss_icon.py" "$STAGE/plain.png" "$STAGE/Assets/$f"
done
echo "$(ls "$STAGE/Assets" | wc -l | tr -d ' ') files"
tar -C "$STAGE" -cf - Assets | "$DEV" 'mkdir -p /var/mobile/Library/WA4S && rm -rf /var/mobile/Library/WA4S/Assets && tar -C /var/mobile/Library/WA4S -xf - && chown -R mobile:mobile /var/mobile/Library/WA4S && ls /var/mobile/Library/WA4S/Assets' | wc -l # (no wc on the 3GS)
# launch image + sounds as real files (symlinks don't work)
"$DEV" 'A=/var/mobile/Library/WA4S/Assets; for f in Default.png Default@2x.png Default-568h@2x.png Tri-tone.caf Ringtone.caf Xylophone.caf Bell.caf Boing.caf Glass.caf Harp.caf TimePassing.caf; do [ -f "$A/$f" ] && rm -f "/Applications/WA4S.app/$f" && cp "$A/$f" "/Applications/WA4S.app/$f"; done; rm -f /var/mobile/Library/Caches/com.apple.IconsCache/com.aronsz26.wa4s_*; su mobile -c uicache 2>/dev/null || uicache'
echo "Respring needed for a new icon or name (iOS 6): killall -9 SpringBoard"
