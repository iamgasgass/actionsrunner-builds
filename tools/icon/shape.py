# Extract the glyph (body, leaf, eyes) from the attached logo as smooth vector paths.
import numpy as np, json, sys
from PIL import Image
from scipy import ndimage
from skimage import measure

im = np.array(Image.open(sys.argv[1]).convert('RGBA')).astype(float)
r, g, b, a = [im[..., i] for i in range(4)]
# green coverage: the logo's green has g-b ~ 150; white (eyes) and transparency have none
gb = np.clip((g - b) / 140.0, 0, 1)
cov = (a / 255.0) * gb
H, W = cov.shape
pad = 8
cov = np.pad(cov, pad)
mask = cov > 0.5
lab, n = ndimage.label(mask)
sizes = ndimage.sum(mask, lab, range(1, n + 1))
order = np.argsort(sizes)[::-1]
body_l, leaf_l = order[0] + 1, order[1] + 1
out = {}
for name, l in (('body', body_l), ('leaf', leaf_l)):
    m = lab == l
    filled = ndimage.binary_fill_holes(m)
    # subpixel outline of this component from the soft coverage, restricted to it
    soft = np.where(ndimage.binary_dilation(filled, iterations=3), cov, 0)
    if name == 'body':
        soft = np.where(ndimage.binary_dilation(filled, iterations=3), np.maximum(soft, filled.astype(float) * (1 - (ndimage.binary_dilation(m, iterations=0) == 0) * 0)), 0)
    soft_fill = np.maximum(soft, ndimage.binary_erosion(filled, iterations=2).astype(float))
    cs = measure.find_contours(soft_fill, 0.5)
    c = max(cs, key=len)
    c = c - pad
    out[name] = [[float(x), float(y)] for y, x in c]
    if name == 'body':
        holes = filled & ~m
        hl, hn = ndimage.label(holes)
        eyes = []
        for i in range(1, hn + 1):
            ys, xs = np.where(hl == i)
            if len(ys) < 50: continue
            # the hole plus its anti-aliased rim: area of (1 - coverage) over the hole's neighbourhood
            region = ndimage.binary_dilation(hl == i, iterations=3)
            area = float(np.sum((1 - cov[region])))
            cy, cx = ys.mean() - pad, xs.mean() - pad
            eyes.append([float(cx), float(cy), float(np.sqrt(area / np.pi))])
        eyes.sort()
        out['eyes'] = eyes
json.dump(out, open(sys.argv[2], 'w'))
print({k: (len(v) if k != 'eyes' else v) for k, v in out.items()})
