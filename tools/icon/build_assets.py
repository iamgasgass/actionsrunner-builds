#!/usr/bin/env python3
"""Cut iLoader X's icon assets from the masters tools/icon/render.mjs made.

    node tools/icon/render.mjs build/icon
    python3 tools/icon/build_assets.py build/icon

Writes, under ios-app/:
  AppIcon.icon/                      Icon Composer document (iOS 26+ Liquid Glass,
                                     with Default / Dark / Clear / Tinted)
  Assets.xcassets/AppIcon.appiconset Liquid Glass look for iOS 17.4 - 25: every
                                     legacy size, plus Dark and Tinted (iOS 18+)
  Assets.xcassets/AppIcon-iOS6.appiconset  the iOS 6 alternate icon, same set
  Assets.xcassets/AppLogo.imageset   in-app logo tile (light + dark)
  Assets.xcassets/IconPreviewIOS6.imageset  the iOS 6 tile for the icon picker
and docs/icon.png, docs/icon-variants.png.
"""
import json
import shutil
import sys
from pathlib import Path

from PIL import Image

src = Path(sys.argv[1] if len(sys.argv) > 1 else "build/icon")
root = Path(__file__).resolve().parents[2]
app = root / "ios-app"
xc = app / "Assets.xcassets"

# (idiom, size in points, scale, filename suffix) — every slot iOS 17.4+ reads,
# iPhone, iPad, CarPlay and the App Store.
SLOTS = [
    ("iphone", "20x20", 2, "-20@2x"), ("iphone", "20x20", 3, "-20@3x"),
    ("iphone", "29x29", 1, "-29"), ("iphone", "29x29", 2, "-29@2x"), ("iphone", "29x29", 3, "-29@3x"),
    ("iphone", "40x40", 2, "-40@2x"), ("iphone", "40x40", 3, "-40@3x"),
    ("iphone", "60x60", 2, "@2x"), ("iphone", "60x60", 3, "@3x"),
    ("ipad", "20x20", 1, "-20~ipad"), ("ipad", "20x20", 2, "-20@2x~ipad"),
    ("ipad", "29x29", 1, "-29~ipad"), ("ipad", "29x29", 2, "-29@2x~ipad"),
    ("ipad", "40x40", 1, "-40~ipad"), ("ipad", "40x40", 2, "-40@2x~ipad"),
    ("ipad", "76x76", 1, "~ipad"), ("ipad", "76x76", 2, "@2x~ipad"),
    ("ipad", "83.5x83.5", 2, "-83.5@2x~ipad"),
    ("car", "60x60", 2, "-60@2x~car"), ("car", "60x60", 3, "-60@3x~car"),
    ("ios-marketing", "1024x1024", 1, "~ios-marketing"),
]


def opaque(im, bg=(255, 255, 255)):
    """App icons for the light slots must have no alpha channel."""
    base = Image.new("RGB", im.size, bg)
    base.paste(im, mask=im.split()[3])
    return base


def save_json(path, obj):
    path.write_text(json.dumps(obj, indent=2) + "\n")


def appiconset(name, light, dark, tinted):
    d = xc / f"{name}.appiconset"
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    master = opaque(Image.open(src / light).convert("RGBA"))
    images = []
    for idiom, size, scale, suffix in SLOTS:
        px = round(float(size.split("x")[0]) * scale)
        fn = f"{name}{suffix}.png"
        master.resize((px, px), Image.LANCZOS).save(d / fn, optimize=True)
        images.append({"filename": fn, "idiom": idiom, "scale": f"{scale}x", "size": size})
    # iOS 18+: the single-size universal slots, one per appearance.
    master.save(d / f"{name}-Light.png", optimize=True)
    images.append({"filename": f"{name}-Light.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"})
    for value, file in (("dark", dark), ("tinted", tinted)):
        fn = f"{name}-{value.capitalize()}.png"
        Image.open(src / file).convert("RGBA").save(d / fn, optimize=True)
        images.append({
            "appearances": [{"appearance": "luminosity", "value": value}],
            "filename": fn, "idiom": "universal", "platform": "ios", "size": "1024x1024",
        })
    save_json(d / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})


def tile(file, size, bg):
    im = Image.open(src / file).convert("RGBA")
    return opaque(im, bg).resize((size, size), Image.LANCZOS)


def imageset(name, light, dark, dark_bg=(18, 20, 22)):
    d = xc / f"{name}.imageset"
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    tile(light, 256, (255, 255, 255)).save(d / f"{name}.png", optimize=True)
    tile(dark, 256, dark_bg).save(d / f"{name}-Dark.png", optimize=True)
    save_json(d / "Contents.json", {
        "images": [
            {"filename": f"{name}.png", "idiom": "universal"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "filename": f"{name}-Dark.png", "idiom": "universal"},
        ],
        "info": {"author": "xcode", "version": 1},
    })


def srgb(r, g, b, a=1.0):
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"


def hexc(h, a=1.0):
    h = h.lstrip("#")
    return srgb(*(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)), a)


def icon_composer():
    """AppIcon.icon: three glyph layers in two glass groups, with a fill per appearance."""
    d = app / "AppIcon.icon"
    if d.exists():
        shutil.rmtree(d)
    (d / "Assets").mkdir(parents=True)
    for n in ("Letter", "Arrow", "Tray"):
        shutil.copy(src / f"layer-{n}.svg", d / "Assets" / f"{n}.svg")

    def layer(name, light, dark, tinted, opacity_tinted=1.0):
        return {
            "fill-specializations": [
                {"value": {"automatic-gradient": light}},
                {"appearance": "dark", "value": {"automatic-gradient": dark}},
                {"appearance": "tinted", "value": {"solid": tinted}},
            ],
            "opacity-specializations": [
                {"value": 1},
                {"appearance": "tinted", "value": opacity_tinted},
            ],
            "glass": True,
            "hidden": False,
            "image-name": f"{name}.svg",
            "name": name,
            "position": {"scale": 1, "translation-in-points": [0, 0]},
        }

    doc = {
        "fill-specializations": [
            {"value": {"linear-gradient": [hexc("#FFFFFF"), hexc("#E4F1E8")],
                       "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 0.7}}}},
            {"appearance": "dark",
             "value": {"linear-gradient": [hexc("#1A231D"), hexc("#000000")],
                       "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 0.7}}}},
        ],
        "groups": [
            {   # front: the download arrow and its tray
                "layers": [
                    layer("Arrow", hexc("#1E6B42"), hexc("#FFFFFF"), hexc("#FFFFFF")),
                    layer("Tray", hexc("#1E6B42"), hexc("#FFFFFF"), hexc("#FFFFFF")),
                ],
                "lighting": "combined",
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.2},
            },
            {   # back: the L
                "layers": [layer("Letter", hexc("#19C566"), hexc("#2BD97A"), hexc("#FFFFFF"), 0.78)],
                "lighting": "individual",
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.35},
            },
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    save_json(d / "icon.json", doc)


icon_composer()
appiconset("AppIcon", "glass-light.png", "glass-dark.png", "glass-tinted.png")
appiconset("AppIcon-iOS6", "ios6-light.png", "ios6-dark.png", "ios6-tinted.png")
imageset("AppLogo", "glass-light.png", "glass-dark.png")
imageset("IconPreviewIOS6", "ios6-light.png", "ios6-dark.png")
(root / "docs").mkdir(exist_ok=True)
tile("glass-light.png", 512, (255, 255, 255)).save(root / "docs" / "icon.png", optimize=True)
shutil.copy(src / "preview.png", root / "docs" / "icon-variants.png")
print("assets written")
