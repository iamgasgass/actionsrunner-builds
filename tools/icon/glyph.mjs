// iLoader X icon artwork: shared geometry, on a 1024 × 1024 canvas.
//
// The glyph is drawn from scratch for iLoader X (not traced from iloader's
// icon): a chunky rounded "L", and in the notch it leaves a download arrow
// landing on a tray.

/** A closed polygon with every corner rounded; radii per corner. */
export function roundedPolygon(points, radii) {
  const n = points.length;
  const k = 0.5523; // cubic approximation of a quarter circle
  let d = "";
  for (let i = 0; i < n; i++) {
    const p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n];
    const r = Array.isArray(radii) ? radii[i] : radii;
    const v1 = norm([p0[0] - p1[0], p0[1] - p1[1]]);
    const v2 = norm([p2[0] - p1[0], p2[1] - p1[1]]);
    const a = [p1[0] + v1[0] * r, p1[1] + v1[1] * r];
    const b = [p1[0] + v2[0] * r, p1[1] + v2[1] * r];
    const c1 = [a[0] - v1[0] * r * k, a[1] - v1[1] * r * k];
    const c2 = [b[0] - v2[0] * r * k, b[1] - v2[1] * r * k];
    d += (i === 0 ? "M" : "L") + f(a) + "C" + f(c1) + " " + f(c2) + " " + f(b);
  }
  return d + "Z";
}
const norm = ([x, y]) => { const l = Math.hypot(x, y); return [x / l, y / l]; };
const f = ([x, y]) => `${x.toFixed(2)},${y.toFixed(2)}`;

// The "L": stem 220 wide, foot 220 tall. Outer corners 78, the inner one 40.
export const L_PATH = roundedPolygon(
  [[226, 196], [446, 196], [446, 604], [806, 604], [806, 824], [226, 824]],
  [78, 78, 40, 78, 78, 78],
);

// The arrow: a shaft and a chevron, as strokes with round ends.
export const ARROW = { x: 640, top: 182, tip: 440, half: 94, width: 70 };
export const ARROW_PATH =
  `M${ARROW.x},${ARROW.top} L${ARROW.x},${ARROW.tip - 8} ` +
  `M${ARROW.x - ARROW.half},${ARROW.tip - ARROW.half} L${ARROW.x},${ARROW.tip} L${ARROW.x + ARROW.half},${ARROW.tip - ARROW.half}`;

// The tray it lands on.
export const TRAY = { x: 516, y: 494, w: 248, h: 58 };
export const TRAY_PATH = roundedPolygon(
  [[TRAY.x, TRAY.y], [TRAY.x + TRAY.w, TRAY.y], [TRAY.x + TRAY.w, TRAY.y + TRAY.h], [TRAY.x, TRAY.y + TRAY.h]],
  TRAY.h / 2 - 0.01,
);

/** Arrow as a filled outline (strokes don't take gradients and filters as well). */
export function arrowStroke(attrs = "") {
  return `<path d="${ARROW_PATH}" fill="none" stroke-width="${ARROW.width}" stroke-linecap="round" stroke-linejoin="round" ${attrs}/>`;
}

/** iOS app-icon superellipse (continuous corners), for previews only: iOS masks the real icon itself. */
export function squirclePath(size = 1024) {
  const n = 5, pts = [];
  for (let i = 0; i < 360; i++) {
    const t = (i / 360) * 2 * Math.PI;
    const c = Math.cos(t), s = Math.sin(t);
    pts.push([
      size / 2 + (size / 2) * Math.sign(c) * Math.abs(c) ** (2 / n),
      size / 2 + (size / 2) * Math.sign(s) * Math.abs(s) ** (2 / n),
    ]);
  }
  return "M" + pts.map(f).join("L") + "Z";
}
