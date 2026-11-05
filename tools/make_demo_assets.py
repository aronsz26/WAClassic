"""Draws the pictures of the bridge's demo mode (for App Store-style screenshots without real chats):
profile pictures (a person on a coloured background, groups with two people) and a holiday photo.
Usage: python3 make_demo_assets.py bridge/demo
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
S = 640


def gradient(size, top, bottom):
    img = Image.new("RGB", size)
    d = ImageDraw.Draw(img)
    w, h = size
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def person(d, cx, base, scale, color, hair=None):
    """Head and shoulders, from the bottom edge up."""
    r = 0.17 * S * scale
    head_y = base - 0.50 * S * scale
    d.ellipse((cx - 0.33 * S * scale, base - 0.24 * S * scale, cx + 0.33 * S * scale, base + 0.36 * S * scale), fill=color)
    d.ellipse((cx - r, head_y - r, cx + r, head_y + r), fill=color)
    if hair:
        d.chord((cx - r * 1.05, head_y - r * 1.12, cx + r * 1.05, head_y + r * 0.6), 180, 360, fill=hair)


people = {
    # top color, bottom color, hair
    "emma": ((255, 183, 150), (233, 110, 98), (92, 58, 40)),
    "jake": ((140, 200, 255), (60, 120, 220), (40, 32, 28)),
    "olivia": ((200, 170, 255), (130, 90, 210), (180, 120, 60)),
    "daniel": ((130, 220, 200), (40, 150, 140), (30, 30, 30)),
    "sophie": ((255, 210, 120), (240, 150, 50), (120, 70, 40)),
    "mom": ((255, 170, 200), (210, 90, 140), (150, 110, 90)),
    "liam": ((170, 210, 140), (90, 150, 70), (70, 50, 35)),
    "me": ((150, 190, 230), (70, 110, 170), (60, 45, 35)),
}
for name, (top, bottom, hair) in people.items():
    img = gradient((S, S), top, bottom)
    d = ImageDraw.Draw(img)
    person(d, S / 2, S * 0.98, 1.0, (250, 248, 245), hair)
    img.save(os.path.join(out, f"avatar-{name}.jpg"), quality=88)

groups = {
    "family": ((255, 200, 140), (230, 120, 80)),
    "trip": ((120, 210, 240), (40, 130, 200)),
    "bookclub": ((190, 200, 120), (120, 140, 60)),
}
for name, (top, bottom) in groups.items():
    img = gradient((S, S), top, bottom)
    d = ImageDraw.Draw(img)
    person(d, S * 0.36, S * 1.0, 0.78, (235, 232, 228))
    person(d, S * 0.64, S * 1.02, 0.86, (252, 250, 247))
    img.save(os.path.join(out, f"avatar-{name}.jpg"), quality=88)

# sunset photo
W, H = 1280, 960
img = gradient((W, H), (255, 170, 110), (120, 80, 160))
d = ImageDraw.Draw(img)
d.ellipse((W * 0.58, H * 0.30, W * 0.72, H * 0.30 + W * 0.14), fill=(255, 225, 160))
for layer, (col, base, amp, seed) in enumerate([((150, 90, 140), 0.56, 0.16, 1.3), ((95, 60, 110), 0.63, 0.12, 2.1),
                                                ((55, 40, 80), 0.70, 0.08, 3.7)]):
    pts = [(0, H)]
    for x in range(0, W + 1, 8):
        y = H * (base - amp * (0.6 * math.sin(x / W * 6 + seed) + 0.4 * math.sin(x / W * 15 + seed * 2)))
        pts.append((x, y))
    pts.append((W, H))
    d.polygon(pts, fill=col)
lake = gradient((W, int(H * 0.22)), (200, 120, 130), (90, 60, 120))
img.paste(lake, (0, int(H * 0.78)))
img = img.filter(ImageFilter.GaussianBlur(1.2))
img.save(os.path.join(out, "photo-sunset.jpg"), quality=86)
img.resize((100, 75), Image.LANCZOS).save(os.path.join(out, "photo-sunset-thumb.jpg"), quality=80)
print("ok")
