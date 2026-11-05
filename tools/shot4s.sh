#!/bin/bash
# 4s screenshot with the chat area pixelated
# shot4s.sh OUT.png [top bottom [cols rows]], 12x40 hides everything, 40x60 shows layout only
set -euo pipefail
OUT=$1; TOP=${2:-128}; BOTTOM=${3:-960}; COLS=${4:-12}; ROWS=${5:-40}
~/.ish4s 'shot6 /tmp/s.png >/dev/null && cat /tmp/s.png && rm /tmp/s.png' > "$OUT.raw"
uv run --quiet --with pillow python3 -I - "$OUT.raw" "$OUT" "$TOP" "$BOTTOM" "$COLS" "$ROWS" <<'PY'
import sys
from PIL import Image
src, out, top, bottom, cols, rows = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:7])
img = Image.open(src).convert("RGB")
box = (0, top, img.width, bottom)
region = img.crop(box)
img.paste(region.resize((cols, rows), Image.BOX).resize(region.size, Image.NEAREST), box)
img.save(out)
PY
rm -f "$OUT.raw"
