#!/bin/bash
# patched meowcaller copy in build/meowcaller (replace in go.mod)
# inbound-relay: don't use our own relay when no is_fna in the offer, it never forwards audio
# (meowcaller #40)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(awk '$1 == "github.com/purpshell/meowcaller" && $2 ~ /^v/ {print $2; exit}' go.mod)
SRC=$(GOFLAGS=-mod=mod go mod download -json "github.com/purpshell/meowcaller@$VERSION" | sed -n 's/.*"Dir": "\(.*\)".*/\1/p')
rm -rf build/meowcaller
mkdir -p build
cp -R "$SRC" build/meowcaller
chmod -R u+w build/meowcaller
patch -s -d build/meowcaller -p1 < patches/meowcaller-inbound-relay.patch
# video-orientation: set the CVO bits, meowcaller always sent 0 (peer saw us sideways)
patch -s -d build/meowcaller -p1 < patches/meowcaller-video-orientation.patch
# video-reorder: wait for late packets (up to 10) instead of treating them as lost
patch -s -d build/meowcaller -p1 < patches/meowcaller-video-reorder.patch
# video-loss: only drop the broken frame, whatsapp recovers via LTR so waiting for an IDR froze video
patch -s -d build/meowcaller -p1 < patches/meowcaller-video-loss.patch
# video-headerlog (debug): log rtp headers of the first 150 video packets
patch -s -d build/meowcaller -p1 < patches/meowcaller-video-headerlog.patch
# callee: send <accept> right away with the capability, don't echo relaylatency (like whatsapp-rust).
# fixes answering calls (meowcaller #37/#40). env switches to go back:
# WA4S_CALLEE_ACCEPT=mute_v2, WA4S_CALLEE_RL=echo|own, WA4S_CALLEE_RELAY=own, WA4S_RELAY_PORT=3480
patch -s -d build/meowcaller -p1 < patches/meowcaller-callee.patch
# video-feedbacklog (debug): log peer RTCP about our video every 5s
patch -s -d build/meowcaller -p1 < patches/meowcaller-video-feedbacklog.patch
# video-deltafi: non-key frames use frame info 0x00 like an iphone (WA4S_VIDEO_DELTA_FI=0x20 for old)
patch -s -d build/meowcaller -p1 < patches/meowcaller-video-deltafi.patch
# video-pack (debug): WA4S_VIDEO_PACK=nal packetizes per NAL (STAP-A/FU-A)
patch -s -d build/meowcaller -p1 < patches/meowcaller-video-pack.patch
# video-ext (debug): WA4S_VIDEO_EXT_BW=n fills rtp ext 5/6 like an iphone
patch -s -d build/meowcaller -p1 < patches/meowcaller-video-ext.patch
