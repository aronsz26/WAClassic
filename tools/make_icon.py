"""Draws WA Classic's app icon: glossy green with rays, white speech bubble ring, "WA" inside.

Comes out finished (gloss and rounded corners), SpringBoard doesn't mask apps in /Applications.
Usage: python3 make_icon.py OUTDIR  -> OUTDIR/icon-57.png, icon-114.png, icon-512.png
"""
import os
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

S = 2048
out = sys.argv[1]
y, x = np.mgrid[0:S, 0:S].astype(float) + 0.5
u, v = x / S, y / S

# dark in the middle, lighter towards the edge, faint rays
dist = np.hypot(u - 0.5, v - 0.56)
t = np.clip(dist / 0.72, 0, 1)[..., None] ** 1.25
c = np.array([8, 138, 22], float) * (1 - t) + np.array([104, 214, 86], float) * t
angle = np.arctan2(v - 0.56, u - 0.5)
rays = (0.5 + 0.5 * np.cos(angle * 26)) ** 3 * np.clip((dist - 0.1) / 0.5, 0, 1)
c = c + (255 - c) * (0.13 * rays)[..., None]


def bubble(grow=0.0):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    cx, cy, r = S * 0.51, S * 0.46, S * (0.335 + grow)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
    return m


def tail(inset=0.0):
    k = inset
    return [(S * (0.235 + k * 1.1), S * (0.60 - k * 0.1)), (S * (0.155 + k * 2.1), S * (0.85 - k * 1.5)),
            (S * (0.40 - k * 0.1), S * (0.765 - k * 0.8))]


line = 0.058
outer = bubble()
ImageDraw.Draw(outer).polygon(tail(), fill=255)
inner = bubble(-line)
ImageDraw.Draw(inner).polygon(tail(line), fill=255)
ring = ImageChops.subtract(outer, inner).filter(ImageFilter.GaussianBlur(S * 0.0012))

font = None
for path in ("/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Helvetica.ttc"):
    if os.path.exists(path):
        for index in (1, 0):  # bold first
            try:
                font = ImageFont.truetype(path, int(S * 0.255), index=index)
                break
            except OSError:
                pass
    if font:
        break
text = Image.new("L", (S, S), 0)
td = ImageDraw.Draw(text)
box = td.textbbox((0, 0), "WA", font=font)
td.text((S * 0.51 - (box[2] - box[0]) / 2 - box[0], S * 0.46 - (box[3] - box[1]) / 2 - box[1]), "WA", font=font, fill=255)

mark = ImageChops.lighter(ring, text)
shadow = Image.new("L", (S, S), 0)
shadow.paste(mark.filter(ImageFilter.GaussianBlur(S * 0.009)), (0, int(S * 0.009)))
c = c * (1 - 0.3 * np.asarray(shadow, float)[..., None] / 255)
c = c + (255 - c) * (np.asarray(mark, float)[..., None] / 255)

# gloss: curved edge below the middle, stronger towards the top
edge = 0.515 - 0.17 * ((u - 0.5) * 2) ** 2
band = np.clip((edge - v) / 0.006, 0, 1)
gloss = (0.3 + 0.48 * np.clip(1 - v / 0.5, 0, 1) ** 1.2) * band
c = c + (255 - c) * gloss[..., None]

# rounded corners, ios 6 radius
R = 0.157 * S
qx = np.maximum(np.abs(x - S / 2) - (S / 2 - R), 0)
qy = np.maximum(np.abs(y - S / 2) - (S / 2 - R), 0)
alpha = np.clip(R - np.hypot(qx, qy) + 0.5, 0, 1) * 255
rgba = np.dstack([np.clip(c, 0, 255), alpha]).round().astype("uint8")
image = Image.fromarray(rgba, "RGBA")

os.makedirs(out, exist_ok=True)
for size in (57, 114, 512):
    image.resize((size, size), Image.LANCZOS).save(os.path.join(out, f"icon-{size}.png"), optimize=True)
