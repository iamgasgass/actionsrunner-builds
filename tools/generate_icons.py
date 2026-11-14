#!/usr/bin/env python3
"""Genera le icone di GassMaps (principale + alternative) nell'asset catalog."""
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "GassMaps", "Assets.xcassets")
S = 1024


def radial(c_in, c_out):
    img = Image.new("RGB", (S, S), c_out)
    px = img.load()
    cx = cy = S / 2
    maxd = math.hypot(cx, cy)
    for y in range(S):
        for x in range(S):
            t = min(1.0, math.hypot(x - cx, y - cy) / maxd)
            t = t ** 1.2
            px[x, y] = tuple(int(c_in[i] * (1 - t) + c_out[i] * t) for i in range(3))
    return img


def make(bg_in, bg_out, line, arrow_l, arrow_r, glow):
    img = radial(bg_in, bg_out).convert("RGBA")
    d = ImageDraw.Draw(img)
    cx, cy = S // 2, int(S * 0.53)
    # croce di mira
    d.line([(60, cy), (S - 60, cy)], fill=line, width=6)
    d.line([(cx, 120), (cx, S - 90)], fill=line, width=6)
    # freccia con ombra/glow
    pts_l = [(cx, cy - 300), (cx - 210, cy + 230), (cx, cy + 120)]
    pts_r = [(cx, cy - 300), (cx + 210, cy + 230), (cx, cy + 120)]
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.polygon(pts_l + pts_r[1:2], fill=glow)
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    img = Image.alpha_composite(img, shadow)
    d = ImageDraw.Draw(img)
    d.polygon(pts_l, fill=arrow_l)
    d.polygon(pts_r, fill=arrow_r)
    return img.convert("RGB")


ICONS = {
    "AppIcon": make((40, 40, 44), (6, 6, 8), (255, 255, 255, 70), (255, 255, 255, 255), (200, 200, 205, 255), (0, 0, 0, 200)),
    "AppIconLight": make((255, 255, 255), (214, 216, 222), (0, 0, 0, 60), (25, 25, 28, 255), (70, 70, 76, 255), (0, 0, 0, 90)),
    "AppIconNeon": make((126, 44, 245), (28, 6, 60), (255, 255, 255, 80), (255, 255, 255, 255), (214, 190, 255, 255), (255, 60, 160, 160)),
}

PREVIEW = {"AppIcon": "IconPreviewDefault", "AppIconLight": "IconPreviewLight", "AppIconNeon": "IconPreviewNeon"}


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def main():
    os.makedirs(ASSETS, exist_ok=True)
    write_json(os.path.join(ASSETS, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    for name, img in ICONS.items():
        folder = os.path.join(ASSETS, f"{name}.appiconset")
        os.makedirs(folder, exist_ok=True)
        img.save(os.path.join(folder, "icon-1024.png"))
        write_json(os.path.join(folder, "Contents.json"), {
            "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        })
        pv = os.path.join(ASSETS, f"{PREVIEW[name]}.imageset")
        os.makedirs(pv, exist_ok=True)
        img.resize((240, 240), Image.LANCZOS).save(os.path.join(pv, "preview.png"))
        write_json(os.path.join(pv, "Contents.json"), {
            "images": [{"filename": "preview.png", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
        })
    for cname, rgb in {"AccentColor": (0.18, 0.55, 1.0), "LaunchBackground": (0, 0, 0)}.items():
        folder = os.path.join(ASSETS, f"{cname}.colorset")
        os.makedirs(folder, exist_ok=True)
        write_json(os.path.join(folder, "Contents.json"), {
            "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
                "red": str(rgb[0]), "green": str(rgb[1]), "blue": str(rgb[2]), "alpha": "1.000"}}}],
            "info": {"author": "xcode", "version": 1},
        })
    print("Icone generate")


if __name__ == "__main__":
    main()
