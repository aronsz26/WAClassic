"""Bakes the iOS 6 look into an app icon: the top gloss and the rounded corners.

SpringBoard on iOS 6 doesn't mask or gloss apps in /Applications (they count as system apps), so their icons must
come finished, like Cydia's. Usage: python3 gloss_icon.py in.png out.png
"""
import sys

import numpy as np
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
img = Image.open(src).convert("RGB")
size = img.width
ss = 4  # supersampling for smooth corners
S = size * ss
c = np.asarray(img.resize((S, S), Image.LANCZOS), dtype=float)
y, x = np.mgrid[0:S, 0:S].astype(float) + 0.5
u, v = x / S, y / S

# gloss band on the top half
strength = 0.35 + 0.65 * np.clip(1 - v / 0.5, 0, 1) ** 1.3
edge = 0.5 - 0.16 * ((u - 0.5) * 2) ** 2
band = np.clip((edge - v) / 0.025, 0, 1)
c = c + (255 - c) * (0.30 * strength * band)[..., None]

# ios 6 corner radius ~0.157 * size
R = 0.157 * S
qx = np.maximum(np.abs(x - S / 2) - (S / 2 - R), 0)
qy = np.maximum(np.abs(y - S / 2) - (S / 2 - R), 0)
inside = (np.hypot(qx, qy) <= R).astype(float)
a = inside.reshape(size, ss, size, ss).mean(axis=(1, 3))
rgb = (c.reshape(size, ss, size, ss, 3) * inside.reshape(size, ss, size, ss)[..., None]).mean(axis=(1, 3))
rgb = rgb / np.maximum(a, 1e-6)[..., None]
out = np.concatenate([np.clip(rgb, 0, 255), (a * 255)[..., None]], axis=2).round().astype(np.uint8)
Image.fromarray(out, "RGBA").save(dst)
