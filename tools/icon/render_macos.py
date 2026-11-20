# SPDX-License-Identifier: GPL-2.0-or-later
#
# Henge X app icon, made as WindowsiOS X's (tools/icon/render_windows.py on that branch), which follows
# Husk's icon: Husk drew Android's head as an Apple apple (with the bite and the leaf), WindowsiOS X gave
# Windows' four panes the bite and the leaf; here a macOS window (title bar and traffic lights) gets them.
# Same glass look, same rounded square, same leaf, in macOS's violet and blue.
#
#   python3 tools/icon/render_macos.py tools/icon/husk_leaf.json tools/icon/squircle.png <out-dir>
#
# husk_leaf.json is the leaf path from Husk's shape.json; squircle.png is any 1024 px icon whose
# alpha is the rounded square (Husk's Icon-Default.png). Needs numpy, scipy and Pillow.
import json, os, sys
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

S = 2048
leaf_pts = np.array(json.load(open(sys.argv[1]))['leaf'], float)
squircle_src = sys.argv[2]
outdir = sys.argv[3]
os.makedirs(outdir, exist_ok=True)

yy, xx = np.mgrid[0:S, 0:S].astype(float)

# ---- the glyph: a macOS window, as WindowsiOS X drew Windows' four panes: a rounded window with its
# title bar (a thin seam under it) and the three traffic lights, with Apple's bite out of the right
# side and Husk's leaf on top. The whole glyph (window + leaf) is centred in the icon.
W = S * 0.50                  # the window's width
H = W * 0.80                  # and height (a Mac window, a little wider than tall)
R = W * 0.085                 # its corner radius (macOS windows are rounded)
BAR = H * 0.20                # the title bar
SEAM = S * 0.010              # the seam between the title bar and the content
LEAF_H = W * 0.36             # leaf height
LEAF_GAP = W * 0.035          # between the leaf's foot and the window
gh = LEAF_H + LEAF_GAP + H    # glyph height
X0 = (S - W) / 2              # window centred horizontally
Y0 = (S - gh) / 2 + LEAF_H + LEAF_GAP   # and the glyph centred vertically

def rbox(x0, y0, x1, y1, r):  # anti-aliased rounded rectangle
    cx = np.clip(xx, x0 + r, x1 - r); cy = np.clip(yy, y0 + r, y1 - r)
    return np.clip(r - np.hypot(xx - cx, yy - cy) + 0.5, 0, 1)
def disc_px(cx, cy, r):
    return np.clip(r - np.hypot(xx - cx, yy - cy) + 0.5, 0, 1)

panes = rbox(X0, Y0, X0 + W, Y0 + H, R)
# the seam under the title bar
seam_y = Y0 + BAR
panes = np.minimum(panes, 1 - np.clip(SEAM / 2 - np.abs(yy - seam_y) + 0.5, 0, 1))
# the bite: a circle eating into the right edge, below the title bar
panes = np.minimum(panes, 1 - disc_px(X0 + W + W * 0.13, Y0 + BAR + (H - BAR) * 0.42, W * 0.22))
# the three traffic lights, in the title bar
LIGHT_R = BAR * 0.20
lights = []
for k in range(3):
    lights.append(disc_px(X0 + R * 0.95 + LIGHT_R + k * LIGHT_R * 3.0, Y0 + BAR * 0.5, LIGHT_R))

# Husk's leaf, standing on the window's top edge, just right of centre (where Apple's stem is).
lp = leaf_pts - leaf_pts.min(0)
lp = lp / lp[:, 1].max() * LEAF_H
lp = lp + np.array([S / 2 - lp[:, 0].min() + W * 0.01, Y0 - LEAF_GAP - lp[:, 1].max()])
img = Image.new('L', (S * 2, S * 2), 0)
ImageDraw.Draw(img).polygon([tuple(q) for q in lp * 2], fill=255)
leaf = np.array(img.resize((S, S), Image.LANCZOS)).astype(float) / 255

# centre the glyph horizontally including the leaf (the leaf leans right)
gx0 = min(X0, lp[:, 0].min()); gx1 = max(X0 + W, lp[:, 0].max())
dx = int(round(S / 2 - (gx0 + gx1) / 2))
panes = np.roll(panes, dx, axis=1); leaf = np.roll(leaf, dx, axis=1)
lights = [np.roll(l, dx, axis=1) for l in lights]

glyph = np.maximum(panes, leaf)
gy0, gy1 = (Y0 - LEAF_GAP - LEAF_H) / S, (Y0 + H) / S
Y, X = yy / S, xx / S
gyn = np.clip((Y - gy0) / (gy1 - gy0), 0, 1)

sq = Image.open(squircle_src).convert('RGBA').split()[3].resize((S, S), Image.LANCZOS)
m_sq = np.array(sq).astype(float) / 255

def lerp(c0, c1, t):
    c0, c1 = np.array(c0, float), np.array(c1, float)
    return c0[None, None, :] * (1 - t[..., None]) + c1[None, None, :] * t[..., None]
def grad3(c0, c1, c2, t, mid=0.5):
    lo = lerp(c0, c1, np.clip(t / mid, 0, 1)); hi = lerp(c1, c2, np.clip((t - mid) / (1 - mid), 0, 1))
    return np.where((t < mid)[..., None], lo, hi)
def over(dst, rgb, alpha):
    a = np.clip(alpha, 0, 1)[..., None]
    if np.ndim(rgb) == 1: rgb = np.array(rgb, float)[None, None, :]
    return dst * (1 - a) + rgb * a
def blur(m, s): return ndimage.gaussian_filter(m, s)
def edge(m, w): return np.clip(m - blur(m, w), 0, 1) * 2.2 * m
def vgrad(stops):
    def f():
        out = lerp(stops[0][1], stops[0][1], Y)
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            t = np.clip((Y - t0) / (t1 - t0), 0, 1)
            out = np.where((Y >= t0)[..., None], lerp(c0, c1, t), out)
        return out
    return f

def make(p):
    im = p['bg']()
    im = over(im, (255, 255, 255), p['sheen'] * np.clip(1 - Y / 0.45, 0, 1) ** 2)
    sh = blur(np.roll(glyph, int(S * 0.018), axis=0), S * 0.018)
    im = over(im, p['shadow'], sh * p['shadow_a'])
    # the window a little lighter towards the light (top left)
    tilt = np.clip(gyn * 0.75 + np.clip((X - 0.3) / 0.45, 0, 1) * 0.25, 0, 1)
    im = over(im, grad3(p['g_top'], p['g_mid'], p['g_bot'], tilt, 0.45), panes * p['g_a'])
    lf = lerp(p['leaf'][0], p['leaf'][1], np.clip((Y - gy0) / ((gy1 - gy0) * 0.35), 0, 1))
    im = over(im, lf, leaf * p['leaf_a'])
    inner = np.clip(glyph - blur(glyph, S * 0.02), 0, 1) * glyph
    im = over(im, p['shade'], inner * p['shade_a'] * (0.4 + 0.6 * gyn))
    im = over(im, p['rim'], edge(glyph, S * 0.004) * p['rim_a'] * (1.0 - 0.55 * gyn))
    im = over(im, (255, 255, 255), glyph * np.clip(1 - gyn / 0.42, 0, 1) ** 1.6 * p['gloss'])
    for l, c in zip(lights, p['lights']):
        im = over(im, c, l * p['lights_a'])
    sq_edge = np.clip(m_sq - blur(m_sq, S * 0.006), 0, 1) * m_sq
    im = over(im, p['sq_rim'], sq_edge * p['sq_rim_a'] * (1 - 0.6 * Y))
    rgba = np.dstack([np.clip(im, 0, 255), m_sq * 255]).astype(np.uint8)
    return Image.fromarray(rgba, 'RGBA').resize((1024, 1024), Image.LANCZOS)

# macOS violet-to-blue where WindowsiOS X had Windows 11 blues; dark and tinted follow Husk's own looks.
LIGHTS = ((255, 95, 87), (254, 188, 46), (40, 200, 64))   # close, minimise, zoom
VARIANTS = {
    'Icon-Default': dict(bg=vgrad([(0, (198, 160, 255)), (0.28, (140, 104, 246)), (0.6, (84, 72, 226)), (1, (26, 44, 150))]), sheen=0.10,
                         shadow=(20, 10, 80), shadow_a=0.62, g_top=(246, 240, 255), g_mid=(206, 196, 255), g_bot=(128, 120, 236), g_a=0.84,
                         leaf=((240, 230, 255), (186, 160, 255)), leaf_a=0.84, shade=(40, 24, 140), shade_a=0.50,
                         rim=(250, 246, 255), rim_a=0.85, gloss=0.22, sq_rim=(255, 255, 255), sq_rim_a=0.35,
                         lights=LIGHTS, lights_a=0.95),
    'Icon-Dark': dict(bg=vgrad([(0, (44, 44, 46)), (0.5, (29, 29, 30)), (1, (17, 17, 17))]), sheen=0.03,
                      shadow=(0, 0, 0), shadow_a=0.6, g_top=(196, 176, 255), g_mid=(130, 104, 240), g_bot=(70, 56, 170), g_a=0.92,
                      leaf=((200, 180, 255), (140, 110, 244)), leaf_a=0.92, shade=(16, 8, 46), shade_a=0.5,
                      rim=(200, 186, 255), rim_a=0.8, gloss=0.08, sq_rim=(255, 255, 255), sq_rim_a=0.12,
                      lights=LIGHTS, lights_a=0.95),
    'Icon-Tinted': dict(bg=vgrad([(0, (36, 36, 38)), (0.5, (30, 30, 32)), (1, (26, 26, 26))]), sheen=0.02,
                        shadow=(0, 0, 0), shadow_a=0.5, g_top=(210, 210, 210), g_mid=(160, 160, 160), g_bot=(120, 120, 120), g_a=0.95,
                        leaf=((220, 220, 220), (170, 170, 170)), leaf_a=0.95, shade=(30, 30, 30), shade_a=0.4,
                        rim=(245, 245, 245), rim_a=0.6, gloss=0.06, sq_rim=(200, 200, 200), sq_rim_a=0.2,
                        lights=((90, 90, 90), (90, 90, 90), (90, 90, 90)), lights_a=0.9),
}
for name, p in VARIANTS.items():
    make(p).save(os.path.join(outdir, name + '.png'), optimize=True)
    print('wrote', name)
