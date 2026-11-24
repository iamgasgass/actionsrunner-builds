#!/usr/bin/env python3
"""Genera l'icona originale di RetroRemote (1024x1024) in stile lucido iOS 6.

Uso: python3 scripts/generate_icon.py  (richiede Pillow)
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "RetroRemote", "Resources",
                   "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")


def vgradient(size, top, bottom):
    w, h = size
    img = Image.new("RGB", size)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def circle_mask(size, box):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).ellipse(box, fill=255)
    return m


# Sfondo: alluminio spazzolato
icon = vgradient((S, S), (214, 218, 224), (150, 156, 166))
rnd = random.Random(7)
d = ImageDraw.Draw(icon)
for y in range(S):
    v = rnd.randint(-10, 10)
    base = icon.getpixel((0, y))
    d.line([(0, y), (S, y)], fill=tuple(max(0, min(255, c + v)) for c in base))

# Anello della croce direzionale
c = S // 2
R = 360
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).ellipse((c - R, c - R + 22, c + R, c + R + 22), fill=(0, 0, 0, 140))
icon.paste(shadow.filter(ImageFilter.GaussianBlur(24)), (0, 0), shadow.filter(ImageFilter.GaussianBlur(24)))

ring = vgradient((S, S), (78, 80, 88), (18, 19, 22))
icon.paste(ring, (0, 0), circle_mask((S, S), (c - R, c - R, c + R, c + R)))
d = ImageDraw.Draw(icon)
d.ellipse((c - R, c - R, c + R, c + R), outline=(8, 8, 10), width=6)

# Frecce
for ang in (0, 90, 180, 270):
    a = math.radians(ang)
    dist = 255
    tip = (c + math.cos(a) * (dist + 55), c + math.sin(a) * (dist + 55))
    bx, by = c + math.cos(a) * (dist - 25), c + math.sin(a) * (dist - 25)
    px, py = -math.sin(a), math.cos(a)
    tri = [tip, (bx + px * 55, by + py * 55), (bx - px * 55, by - py * 55)]
    d.polygon(tri, fill=(225, 228, 235))

# Tasto centrale blu
r = 150
d.ellipse((c - r - 18, c - r - 18, c + r + 18, c + r + 18), fill=(6, 6, 8))
btn = vgradient((S, S), (120, 190, 255), (10, 84, 210))
icon.paste(btn, (0, 0), circle_mask((S, S), (c - r, c - r, c + r, c + r)))

# Riflesso lucido iOS 6
gloss = Image.new("RGBA", (S, S), (0, 0, 0, 0))
g = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(g)
for y in range(int(S * 0.52)):
    alpha = int(150 - 110 * (y / (S * 0.52)))
    gd.line([(0, y), (S, y)], fill=alpha)
ellipse = Image.new("L", (S, S), 0)
ImageDraw.Draw(ellipse).ellipse((-S * 0.5, -S * 0.93, S * 1.5, S * 0.52), fill=255)
from PIL import ImageChops
g = ImageChops.multiply(g, ellipse)
gloss.putalpha(g)
white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
white.putalpha(g)
icon = Image.alpha_composite(icon.convert("RGBA"), white).convert("RGB")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
icon.save(OUT, "PNG")
print("Icona salvata in", os.path.normpath(OUT))
