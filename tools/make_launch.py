# plain launch images (empty app frame), replaced by whatsapp's once synced
# uv run --with pillow python3 tools/make_launch.py app/Launch
import sys
from PIL import Image, ImageDraw

def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

def make(path, w, h, s):
    img = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w, 20 * s], fill=(0, 0, 0))
    top, bottom = 20 * s, 64 * s  # navigation bar: iOS 6's blue-grey gradient
    for y in range(top, bottom):
        d.line([0, y, w, y], fill=lerp((176, 188, 205), (109, 132, 162), (y - top) / (bottom - top)))
    d.line([0, bottom - 1, w, bottom - 1], fill=(45, 62, 86))
    tab = h - 49 * s  # tab bar: black gloss
    for y in range(tab, h):
        t = (y - tab) / (49 * s)
        d.line([0, y, w, y], fill=lerp((62, 62, 62), (22, 22, 22), t * 2) if t < 0.5 else (0, 0, 0))
    d.line([0, tab, w, tab], fill=(90, 90, 90))
    img.save(path, optimize=True)

out = sys.argv[1]
make(f"{out}/Default.png", 320, 480, 1)
make(f"{out}/Default@2x.png", 640, 960, 2)
make(f"{out}/Default-568h@2x.png", 640, 1136, 2)
