# Husk's app icon in all six looks, from the glyph paths in shape.json, in the palette of the previous icon set.
import json, sys, os
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

S = 2048                    # working size; saved at 1024
shape = json.load(open(sys.argv[1]))
squircle_src = sys.argv[2]  # an original icon: its alpha is the rounded-square outline every variant keeps
outdir = sys.argv[3]
os.makedirs(outdir, exist_ok=True)

def smooth(pts, sigma=1.2):
    p = np.array(pts)
    return np.stack([ndimage.gaussian_filter1d(p[:, 0], sigma, mode='wrap'), ndimage.gaussian_filter1d(p[:, 1], sigma, mode='wrap')], 1)

body, leaf = smooth(shape['body']), smooth(shape['leaf'])
eyes = shape['eyes']
allp = np.vstack([body, leaf])
x0, y0 = allp.min(0); x1, y1 = allp.max(0)
gw, gh = x1 - x0, y1 - y0
scale = S * 0.70 / gw                        # the glyph spans two thirds of the icon's width, as the old one did
ox = (S - gw * scale) / 2 - x0 * scale
oy = (S - gh * scale) / 2 - y0 * scale + S * 0.012   # optical centre: a touch low, the leaf is light
def T(p): return p * scale + np.array([ox, oy])

SS = 2   # supersampling for rasterising
def poly_mask(pts):
    img = Image.new('L', (S * SS, S * SS), 0)
    ImageDraw.Draw(img).polygon([tuple(q) for q in (T(pts) * SS)], fill=255)
    return np.array(img.resize((S, S), Image.LANCZOS)).astype(float) / 255
def circle_mask(cx, cy, r):
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    return np.clip(r - d + 0.5, 0, 1)

m_body, m_leaf = poly_mask(body), poly_mask(leaf)
m_glyph = np.maximum(m_body, m_leaf)
E = [(T(np.array([e[0], e[1]]))[0], T(np.array([e[0], e[1]]))[1], e[2] * scale) for e in eyes]
m_socket = np.zeros((S, S)); m_pupil = np.zeros((S, S)); m_socket_rim = np.zeros((S, S))
for cx, cy, r in E:
    m_socket = np.maximum(m_socket, circle_mask(cx, cy, r * 1.42))
    m_pupil = np.maximum(m_pupil, circle_mask(cx, cy, r * 0.88))
    m_socket_rim = np.maximum(m_socket_rim, np.clip(circle_mask(cx, cy, r * 1.42) - circle_mask(cx, cy, r * 1.42 - S * 0.0035), 0, 1))

sq = Image.open(squircle_src).convert('RGBA').split()[3].resize((S, S), Image.LANCZOS)
m_sq = np.array(sq).astype(float) / 255

yy, xx = np.mgrid[0:S, 0:S].astype(float) / S
gy0, gy1 = (y0 * scale + oy) / S, (y1 * scale + oy) / S
gyn = np.clip((yy - gy0) / (gy1 - gy0), 0, 1)       # 0 at the glyph's top, 1 at its bottom

def lerp(c0, c1, t):
    c0, c1 = np.array(c0, float), np.array(c1, float)
    return c0[None, None, :] * (1 - t[..., None]) + c1[None, None, :] * t[..., None]
def grad3(c0, c1, c2, t, mid=0.5):
    lo = lerp(c0, c1, np.clip(t / mid, 0, 1)); hi = lerp(c1, c2, np.clip((t - mid) / (1 - mid), 0, 1))
    return np.where((t < mid)[..., None], lo, hi)

def over(dst, rgb, alpha):
    """Composite a colour layer with per-pixel alpha onto an opaque RGB canvas."""
    a = np.clip(alpha, 0, 1)[..., None]
    if np.ndim(rgb) == 1: rgb = np.array(rgb, float)[None, None, :]
    return dst * (1 - a) + rgb * a

def edge(m, width):
    inner = ndimage.gaussian_filter(m, width)
    return np.clip(m - inner, 0, 1) * 2.2 * m

def blur(m, s): return ndimage.gaussian_filter(m, s)

def make(p):
    img = p['bg'](yy, xx)
    # a soft sheen across the top of the square, as glass catches light
    img = over(img, (255, 255, 255), p.get('sheen', 0.0) * np.clip(1 - yy / 0.45, 0, 1) ** 2)
    # shadow under the glyph
    sh = blur(np.roll(np.maximum(m_glyph, 0), int(S * 0.018), axis=0), S * 0.018)
    img = over(img, p['shadow'], sh * p['shadow_a'])
    # the glyph's glass: a coloured fill, lighter at the top
    fill = grad3(p['g_top'], p['g_mid'], p['g_bot'], gyn, 0.45)
    img = over(img, fill, m_glyph * p['g_a'])
    # leaf in its own colour, as the old ears were
    if 'leaf' in p:
        lf = lerp(p['leaf'][0], p['leaf'][1], np.clip((yy - (gy0)) / ((gy1 - gy0) * 0.45), 0, 1))
        img = over(img, lf, m_leaf * p['leaf_a'])
    # inner glow along the bottom (thickness) and the rim highlight (top-weighted)
    inner_shade = np.clip(m_glyph - blur(m_glyph, S * 0.02), 0, 1) * m_glyph
    img = over(img, p['shade'], inner_shade * p['shade_a'] * (0.4 + 0.6 * gyn))
    rim = edge(m_glyph, S * 0.004)
    img = over(img, p['rim'], rim * p['rim_a'] * (1.0 - 0.55 * gyn))
    # gloss: a highlight band across the upper glyph
    gloss = m_glyph * np.clip(1 - gyn / 0.42, 0, 1) ** 1.6
    img = over(img, (255, 255, 255), gloss * p['gloss'])
    # eyes: a recessed socket with a lit rim, and the lit pupil
    img = over(img, p['socket'], m_socket * p['socket_a'])
    img = over(img, p['rim'], m_socket_rim * p['rim_a'] * 0.9)
    pup = grad3(p['pupil'][0], p['pupil'][1], p['pupil'][1], gyn, 0.5)
    img = over(img, pup, m_pupil)
    img = over(img, (255, 255, 255), edge(m_pupil, S * 0.003) * 0.35)
    # the square's own lit edge
    sq_edge = np.clip(m_sq - blur(m_sq, S * 0.006), 0, 1) * m_sq
    img = over(img, p['sq_rim'], sq_edge * p['sq_rim_a'] * (1 - 0.6 * yy))
    rgba = np.dstack([np.clip(img, 0, 255), m_sq * 255]).astype(np.uint8)
    return Image.fromarray(rgba, 'RGBA').resize((1024, 1024), Image.LANCZOS)

def vgrad(stops):
    def f(yy, xx):
        ts = [s[0] for s in stops]
        out = np.zeros(yy.shape + (3,))
        for i in range(len(stops) - 1):
            t0, c0 = stops[i]; t1, c1 = stops[i + 1]
            t = np.clip((yy - t0) / (t1 - t0), 0, 1)
            sel = (yy >= t0) & (yy <= t1) if i < len(stops) - 2 else (yy >= t0)
            if i == 0: sel = sel | (yy < t0)
            out = np.where(sel[..., None], lerp(c0, c1, t), out)
        return out
    return f

# The palettes, read off the previous icon set: violet-to-blue default, near-black dark, muted tinted, clear greys, flat purple.
VARIANTS = {
    'default': dict(bg=vgrad([(0, (184, 156, 240)), (0.2, (151, 125, 230)), (0.5, (93, 75, 236)), (1, (14, 2, 248))]), sheen=0.10,
                    shadow=(8, 2, 80), shadow_a=0.62, g_top=(206, 198, 255), g_mid=(112, 98, 250), g_bot=(46, 32, 232), g_a=0.78,
                    leaf=((200, 188, 255), (124, 106, 248)), leaf_a=0.8, shade=(22, 10, 150), shade_a=0.6, rim=(240, 236, 255), rim_a=0.85,
                    gloss=0.22, socket=(36, 24, 150), socket_a=0.82, pupil=((214, 206, 255), (176, 164, 244)), sq_rim=(255, 255, 255), sq_rim_a=0.35),
    'dark': dict(bg=vgrad([(0, (44, 43, 44)), (0.5, (29, 29, 30)), (1, (17, 17, 17))]), sheen=0.03,
                 shadow=(0, 0, 0), shadow_a=0.6, g_top=(70, 64, 200), g_mid=(42, 40, 140), g_bot=(24, 26, 84), g_a=0.92,
                 leaf=((96, 82, 236), (70, 58, 200)), leaf_a=0.92, shade=(8, 8, 30), shade_a=0.5, rim=(120, 108, 255), rim_a=0.8,
                 gloss=0.07, socket=(16, 18, 56), socket_a=0.85, pupil=((170, 160, 240), (130, 118, 222)), sq_rim=(255, 255, 255), sq_rim_a=0.12),
    'tinted': dict(bg=vgrad([(0, (37, 33, 50)), (0.5, (31, 29, 40)), (1, (26, 26, 26))]), sheen=0.02,
                   shadow=(0, 0, 0), shadow_a=0.5, g_top=(58, 52, 88), g_mid=(44, 40, 66), g_bot=(34, 31, 48), g_a=0.95,
                   leaf=((70, 60, 112), (54, 46, 88)), leaf_a=0.95, shade=(14, 12, 22), shade_a=0.5, rim=(110, 98, 170), rim_a=0.6,
                   gloss=0.05, socket=(24, 22, 36), socket_a=0.9, pupil=((92, 80, 150), (74, 64, 124)), sq_rim=(120, 100, 200), sq_rim_a=0.25),
    'clearlight': dict(bg=vgrad([(0, (134, 134, 134)), (1, (124, 124, 124))]), sheen=0.10,
                       shadow=(30, 30, 30), shadow_a=0.5, g_top=(206, 206, 206), g_mid=(158, 158, 158), g_bot=(136, 136, 136), g_a=0.6,
                       leaf=((212, 212, 212), (170, 170, 170)), leaf_a=0.65, shade=(80, 80, 80), shade_a=0.45, rim=(252, 252, 252), rim_a=0.9,
                       gloss=0.18, socket=(92, 92, 92), socket_a=0.75, pupil=((232, 232, 232), (206, 206, 206)), sq_rim=(255, 255, 255), sq_rim_a=0.55),
    'cleardark': dict(bg=vgrad([(0, (48, 48, 48)), (1, (40, 40, 40))]), sheen=0.04,
                      shadow=(0, 0, 0), shadow_a=0.6, g_top=(78, 78, 78), g_mid=(54, 54, 54), g_bot=(36, 36, 36), g_a=0.9,
                      leaf=((84, 84, 84), (60, 60, 60)), leaf_a=0.9, shade=(10, 10, 10), shade_a=0.55, rim=(190, 190, 190), rim_a=0.7,
                      gloss=0.06, socket=(22, 22, 22), socket_a=0.9, pupil=((150, 150, 150), (120, 120, 120)), sq_rim=(255, 255, 255), sq_rim_a=0.18),
    'tintedlight': dict(bg=vgrad([(0, (112, 93, 203)), (1, (108, 89, 199))]), sheen=0.06,
                        shadow=(36, 22, 110), shadow_a=0.55, g_top=(190, 178, 248), g_mid=(140, 124, 228), g_bot=(112, 94, 212), g_a=0.72,
                        leaf=((196, 184, 250), (150, 134, 232)), leaf_a=0.78, shade=(56, 40, 146), shade_a=0.5, rim=(240, 236, 255), rim_a=0.85,
                        gloss=0.18, socket=(70, 52, 160), socket_a=0.8, pupil=((210, 202, 255), (184, 174, 246)), sq_rim=(255, 255, 255), sq_rim_a=0.4),
}
for name, p in VARIANTS.items():
    make(p).save(os.path.join(outdir, name + '.png'), optimize=True)
    print('wrote', name)
