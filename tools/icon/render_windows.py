# SPDX-License-Identifier: GPL-2.0-or-later
#
# WindowsiOS Universal app icon, in the style of Husk's icon (tools/icon/render.py on Husk's branch):
# Husk drew Android's head as an Apple apple (with the bite and the leaf); here the apple is cut into
# Windows' four panes. Same glass look, same rounded square, same leaf, Windows 11 blues.
#
#   python3 tools/icon/render_windows.py tools/icon/husk_leaf.json tools/icon/squircle.png <out-dir>
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

# ---- the glyph, in "apple units": the body spans x -0.5..0.5, y 0..1 ----
U = S * 0.50                         # body width in pixels (Husk's glyph spans ~0.70 with its leaf)
CX, CY = S * 0.5 - U * 0.03, S * 0.385  # top of the body; a touch left, the bite takes the right side
ux, uy = (xx - CX) / U, (yy - CY) / U

def disc(cx, cy, r):
    return np.clip((r - np.hypot(ux - cx, uy - cy)) * U + 0.5, 0, 1)
def ell(cx, cy, rx, ry):
    d = np.hypot((ux - cx) / rx, (uy - cy) / ry)
    return np.clip((1 - d) * min(rx, ry) * U + 0.5, 0, 1)

body = np.maximum.reduce([
    disc(-0.22, 0.28, 0.29), disc(0.22, 0.28, 0.29),     # shoulders
    ell(0.0, 0.56, 0.51, 0.40),                          # belly
    disc(-0.19, 0.80, 0.21), disc(0.19, 0.80, 0.21),      # lower lobes
])
# close the waists between the circles: blur wide, keep a low threshold
body = np.clip((ndimage.gaussian_filter(body, S * 0.02) - 0.42) * 8 + 0.5, 0, 1)
body = np.minimum(body, 1 - disc(0.0, -0.035, 0.115))   # dip where the stem goes
body = np.minimum(body, 1 - disc(0.0, 1.06, 0.09))     # dip at the bottom
body = np.minimum(body, 1 - disc(0.60, 0.47, 0.185))    # the bite
body = np.clip((ndimage.gaussian_filter(body, S * 0.004) - 0.5) * 6 + 0.5, 0, 1)  # round the joins

# Windows' four panes: a cross-shaped gap through the body's centre.
GX, GY, GAP = -0.03, 0.52, 0.05
cross = np.maximum(np.clip((GAP / 2 - np.abs(ux - GX)) * U + 0.5, 0, 1),
                   np.clip((GAP / 2 - np.abs(uy - GY)) * U + 0.5, 0, 1))
panes = np.clip(body - cross, 0, 1)

# Husk's leaf, scaled and set above the stem dip.
lp = leaf_pts - leaf_pts.min(0)
lp = lp / lp[:, 1].max() * (0.36 * U)                    # 0.36 body units tall
lp = lp + np.array([CX + U * 0.01 - lp[:, 0].min(), CY + U * 0.005 - lp[:, 1].max()])
img = Image.new('L', (S * 2, S * 2), 0)
ImageDraw.Draw(img).polygon([tuple(q) for q in lp * 2], fill=255)
leaf = np.array(img.resize((S, S), Image.LANCZOS)).astype(float) / 255

glyph = np.maximum(panes, leaf)
gy0, gy1 = (lp[:, 1].min()) / S, (CY + U * 1.02) / S
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
    # each pane a little lighter towards the light (top left), as Windows 11's logo
    tilt = np.clip(gyn * 0.75 + np.clip((X - 0.3) / 0.45, 0, 1) * 0.25, 0, 1)
    im = over(im, grad3(p['g_top'], p['g_mid'], p['g_bot'], tilt, 0.45), panes * p['g_a'])
    lf = lerp(p['leaf'][0], p['leaf'][1], np.clip((Y - gy0) / ((gy1 - gy0) * 0.35), 0, 1))
    im = over(im, lf, leaf * p['leaf_a'])
    inner = np.clip(glyph - blur(glyph, S * 0.02), 0, 1) * glyph
    im = over(im, p['shade'], inner * p['shade_a'] * (0.4 + 0.6 * gyn))
    im = over(im, p['rim'], edge(glyph, S * 0.004) * p['rim_a'] * (1.0 - 0.55 * gyn))
    im = over(im, (255, 255, 255), glyph * np.clip(1 - gyn / 0.42, 0, 1) ** 1.6 * p['gloss'])
    sq_edge = np.clip(m_sq - blur(m_sq, S * 0.006), 0, 1) * m_sq
    im = over(im, p['sq_rim'], sq_edge * p['sq_rim_a'] * (1 - 0.6 * Y))
    rgba = np.dstack([np.clip(im, 0, 255), m_sq * 255]).astype(np.uint8)
    return Image.fromarray(rgba, 'RGBA').resize((1024, 1024), Image.LANCZOS)

# Windows 11 blues where Husk had violet; dark and tinted follow Husk's own dark / tinted looks.
VARIANTS = {
    'Icon-Default': dict(bg=vgrad([(0, (150, 214, 255)), (0.25, (76, 170, 246)), (0.55, (0, 110, 214)), (1, (0, 36, 150))]), sheen=0.10,
                         shadow=(0, 18, 80), shadow_a=0.62, g_top=(214, 240, 255), g_mid=(96, 190, 255), g_bot=(0, 98, 212), g_a=0.80,
                         leaf=((210, 238, 255), (110, 196, 255)), leaf_a=0.82, shade=(0, 40, 140), shade_a=0.55,
                         rim=(236, 248, 255), rim_a=0.85, gloss=0.22, sq_rim=(255, 255, 255), sq_rim_a=0.35),
    'Icon-Dark': dict(bg=vgrad([(0, (44, 44, 46)), (0.5, (29, 29, 30)), (1, (17, 17, 17))]), sheen=0.03,
                      shadow=(0, 0, 0), shadow_a=0.6, g_top=(96, 200, 255), g_mid=(0, 120, 212), g_bot=(0, 58, 140), g_a=0.92,
                      leaf=((110, 206, 255), (0, 132, 222)), leaf_a=0.92, shade=(0, 14, 40), shade_a=0.5,
                      rim=(120, 210, 255), rim_a=0.8, gloss=0.08, sq_rim=(255, 255, 255), sq_rim_a=0.12),
    'Icon-Tinted': dict(bg=vgrad([(0, (36, 36, 38)), (0.5, (30, 30, 32)), (1, (26, 26, 26))]), sheen=0.02,
                        shadow=(0, 0, 0), shadow_a=0.5, g_top=(210, 210, 210), g_mid=(160, 160, 160), g_bot=(120, 120, 120), g_a=0.95,
                        leaf=((220, 220, 220), (170, 170, 170)), leaf_a=0.95, shade=(30, 30, 30), shade_a=0.4,
                        rim=(245, 245, 245), rim_a=0.6, gloss=0.06, sq_rim=(200, 200, 200), sq_rim_a=0.2),
}
for name, p in VARIANTS.items():
    make(p).save(os.path.join(outdir, name + '.png'), optimize=True)
    print('wrote', name)
