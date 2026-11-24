// The in-app tool tiles (Apps, Certificates, Downloads, Entitlements,
// Location, Pairing, Side by Side, JIT, Sources), redrawn in the iLoader X icon's design:
// the same light backdrop and garnet Liquid Glass glyph (lift shadow, inner
// glow, specular rim, sheen) as the app icon, with a dark variant.
//
// JIT and Sources came with SideInstaller 2.2.0 (Tools › JIT, Tools › Sources).
//
// Each glyph is a function of a paint: what it fills or strokes with. Holes
// are cut with masks, so one glass piece covers the whole glyph.

const W = 64; // stroke width of outlines
const line = (d, paint, w = W) =>
  `<path d="${d}" fill="none" stroke="${paint}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"/>`;
const rrect = (x, y, w, h, r, attrs) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" ${attrs}/>`;
const cut = (id, holes) =>
  `<mask id="${id}" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">` +
  `<rect width="1024" height="1024" fill="#fff"/>${holes}</mask>`;

// A scalloped seal: 12 bumps.
function sealPath(cx, cy, r1, r2, n = 12) {
  let d = "";
  for (let i = 0; i < n * 2; i++) {
    const a = (Math.PI * i) / n - Math.PI / 2;
    const r = i % 2 ? r2 : r1;
    d += (i ? "L" : "M") + (cx + r * Math.cos(a)).toFixed(1) + "," + (cy + r * Math.sin(a)).toFixed(1);
  }
  return d + "Z";
}

export const TOOL_DEFS = [
  cut("cutCheck", line("M392,520 L476,604 L640,436", "#000", 72)),
  cut("cutArrow", line("M512,470 L512,650 M430,580 L512,662 L594,580", "#000", 60)),
  cut("cutPin", `<circle cx="512" cy="420" r="92" fill="#000"/>`),
  cut("cutBox", line("M232,340 L512,480 L792,340 M512,480 L512,840 M372,270 L652,410", "#000", 36)),
].join("");

export const TOOLS = {
  // The refresh schedule: a calendar with three dots.
  AppsLogo: (p) =>
    rrect(244, 292, 536, 468, 96, `fill="none" stroke="${p}" stroke-width="${W}"`) +
    `<path d="M244,388 Q244,292 340,292 H684 Q780,292 780,388 V420 H244 Z" fill="${p}"/>` +
    line("M384,232 V316 M640,232 V316", p) +
    [392, 512, 632].map((x) => `<circle cx="${x}" cy="580" r="44" fill="${p}"/>`).join(""),
  // A certificate seal with a check cut out.
  CertsLogo: (p) => `<path d="${sealPath(512, 520, 300, 252)}" fill="${p}" stroke="${p}" stroke-width="40" stroke-linejoin="round" mask="url(#cutCheck)"/>`,
  // A box with a lid, the down arrow cut out of it.
  DownloadsLogo: (p) =>
    `<g mask="url(#cutArrow)">` +
    rrect(220, 250, 584, 128, 48, `fill="${p}"`) +
    rrect(264, 410, 496, 380, 64, `fill="${p}"`) +
    `</g>`,
  // A checklist: two ticks, two lines.
  EntitlementsLogo: (p) =>
    line("M236,372 L300,436 L412,316", p, 60) +
    line("M236,628 L300,692 L412,572", p, 60) +
    line("M500,380 H792 M500,636 H792", p, 60),
  // A map pin with a hole.
  LocationLogo: (p) =>
    `<path d="M512,184 C346,184 222,308 222,466 C222,626 404,760 512,856 C620,760 802,626 802,466 C802,308 678,184 512,184 Z" fill="${p}" mask="url(#cutPin)"/>`,
  // A phone with a lock: pairing.
  PairingLogo: (p) =>
    rrect(300, 176, 424, 672, 84, `fill="none" stroke="${p}" stroke-width="${W - 8}"`) +
    line("M454,480 V432 Q454,374 512,374 Q570,374 570,432 V480", p, 44) +
    rrect(420, 474, 184, 156, 30, `fill="${p}"`) +
    rrect(462, 736, 100, 26, 13, `fill="${p}"`),
  // Another phone, reached over Wi-Fi: Side by Side.
  SideBySideLogo: (p) =>
    rrect(392, 484, 240, 372, 56, `fill="none" stroke="${p}" stroke-width="${W - 8}"`) +
    rrect(472, 774, 80, 24, 12, `fill="${p}"`) +
    line("M396,372 Q512,280 628,372", p, 56) +
    line("M296,292 Q512,120 728,292", p, 56),
  // A lightning bolt: JIT.
  JITLogo: (p) =>
    `<path d="M598,152 L318,566 L494,566 L430,872 L716,436 L538,436 L618,152 Z" fill="${p}" stroke="${p}" stroke-width="36" stroke-linejoin="round"/>`,
  // A package: app sources.
  SourcesLogo: (p) =>
    `<path d="M512,196 L800,340 L800,668 L512,828 L224,668 L224,340 Z" fill="${p}" stroke="${p}" stroke-width="40" stroke-linejoin="round" mask="url(#cutBox)"/>`,
};
