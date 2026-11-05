#!/bin/bash
# 5s/SE screenshot with the chat area pixelated (SHOT_HOST=~/.ishse1 for the SE)
# shot5s.sh OUT.png [top bottom [cols rows]], default keeps only the bars
# needs arm64 shot6 with com.apple.QuartzCore.global-capture
set -euo pipefail
OUT=$1; TOP=${2:-128}; BOTTOM=${3:-1038}; COLS=${4:-12}; ROWS=${5:-40}
HOST=${SHOT_HOST:-$HOME/.ish5s}
"$HOST" 'shot6 /tmp/s.png 640 1136 >/dev/null && cat /tmp/s.png && rm /tmp/s.png' > "$OUT.raw"
uv run --quiet --with pillow python3 -I - "$OUT.raw" "$OUT" "$TOP" "$BOTTOM" "$COLS" "$ROWS" <<'PY'
import sys
from PIL import Image
src, out, top, bottom, cols, rows = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:7])
img = Image.open(src).convert("RGB")
if bottom > top:
    box = (0, top, img.width, bottom)
    region = img.crop(box)
    img.paste(region.resize((cols, rows), Image.BOX).resize(region.size, Image.NEAREST), box)
img.save(out)
PY
rm -f "$OUT.raw"
