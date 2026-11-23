// The two looks of the iLoader X icon, as SVG documents on a 1024 canvas:
//
//   glass(mode)  Liquid Glass (iOS 26 look): flat light backdrop, translucent
//                glyphs with a specular rim, soft lift shadow. Rendered to
//                PNG for the asset catalog (iOS 17.4 - 25) and the previews;
//                on iOS 26+ the system draws the real material from
//                ios-app/AppIcon.icon instead.
//   ios6(mode)   iOS 6 skeuomorphic: linen backdrop, beveled garnet gel "L",
//                embossed gunmetal arrow, the glossy highlight arc baked in.
//
// mode: light | dark | tinted | clear-light | clear-dark (glass) ; light | dark | tinted (ios6)

import { L_PATH, TRAY_PATH, arrowStroke, ARROW_PATH, ARROW } from "./glyph.mjs";

const svg = (body, defs = "") =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">` +
  `<defs>${defs}</defs>${body}</svg>`;

// Shapes as markup with a given fill attribute string.
const shapeL = (a) => `<path d="${L_PATH}" ${a}/>`;
const shapeTray = (a) => `<path d="${TRAY_PATH}" ${a}/>`;
const shapeArrow = (color) => arrowStroke(`stroke="${color}"`);
// Arrow + tray, one unit, filled with a paint (stroke for the arrow).
const shapeDownload = (paint) => shapeArrow(paint) + shapeTray(`fill="${paint}"`);

const lin = (id, stops, x1 = 0, y1 = 0, x2 = 0, y2 = 1, extra = "") =>
  `<linearGradient id="${id}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" ${extra}>` +
  stops.map(([o, c, a = 1]) => `<stop offset="${o}" stop-color="${c}" stop-opacity="${a}"/>`).join("") +
  `</linearGradient>`;
const rad = (id, cx, cy, r, stops, extra = "") =>
  `<radialGradient id="${id}" cx="${cx}" cy="${cy}" r="${r}" ${extra}>` +
  stops.map(([o, c, a = 1]) => `<stop offset="${o}" stop-color="${c}" stop-opacity="${a}"/>`).join("") +
  `</radialGradient>`;

// Shared filters.
const FILTERS = `
  <filter id="lift" x="-20%" y="-20%" width="140%" height="150%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="22"/>
    <feOffset dy="22" result="b"/>
    <feFlood flood-color="#000" flood-opacity="0.22"/><feComposite in2="b" operator="in"/>
  </filter>
  <filter id="contact" x="-20%" y="-20%" width="140%" height="150%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="5"/>
    <feOffset dy="6" result="b"/>
    <feFlood flood-color="#000" flood-opacity="0.18"/><feComposite in2="b" operator="in"/>
  </filter>
  <filter id="rim" x="-10%" y="-10%" width="120%" height="120%">
    <feMorphology in="SourceAlpha" operator="erode" radius="8" result="er"/>
    <feComposite in="SourceAlpha" in2="er" operator="out" result="ring"/>
    <feGaussianBlur in="ring" stdDeviation="1.6" result="rb"/>
    <feComposite in="rb" in2="SourceAlpha" operator="in" result="ri"/>
    <feFlood flood-color="#fff"/><feComposite in2="ri" operator="in"/>
  </filter>
  <filter id="innerGlow" x="-10%" y="-10%" width="120%" height="120%">
    <feMorphology in="SourceAlpha" operator="erode" radius="26" result="er"/>
    <feGaussianBlur in="er" stdDeviation="22" result="eb"/>
    <feComposite in="SourceAlpha" in2="eb" operator="out" result="edge"/>
    <feFlood flood-color="#fff"/><feComposite in2="edge" operator="in"/>
  </filter>
  <filter id="innerShadow" x="-10%" y="-10%" width="120%" height="120%">
    <feOffset in="SourceAlpha" dx="0" dy="-14"/>
    <feGaussianBlur stdDeviation="10" result="o"/>
    <feComposite in="SourceAlpha" in2="o" operator="out" result="s"/>
    <feFlood flood-color="#000"/><feComposite in2="s" operator="in"/>
  </filter>
  <filter id="innerHighlight" x="-10%" y="-10%" width="120%" height="120%">
    <feOffset in="SourceAlpha" dx="0" dy="10"/>
    <feGaussianBlur stdDeviation="5" result="o"/>
    <feComposite in="SourceAlpha" in2="o" operator="out" result="s"/>
    <feFlood flood-color="#fff"/><feComposite in2="s" operator="in"/>
  </filter>
  <filter id="drop6" x="-20%" y="-20%" width="140%" height="150%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="9"/>
    <feOffset dy="12" result="b"/>
    <feFlood flood-color="#000" flood-opacity="0.5"/><feComposite in2="b" operator="in"/>
  </filter>
  <filter id="emboss" x="-20%" y="-20%" width="140%" height="150%">
    <feOffset in="SourceAlpha" dy="4" result="o"/>
    <feFlood flood-color="#fff" flood-opacity="0.85"/><feComposite in2="o" operator="in"/>
  </filter>
  <filter id="linen" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="fractalNoise" baseFrequency="0.9 0.06" numOctaves="2" seed="7" result="n1"/>
    <feTurbulence type="fractalNoise" baseFrequency="0.06 0.9" numOctaves="2" seed="11" result="n2"/>
    <feBlend in="n1" in2="n2" mode="multiply" result="n"/>
    <feColorMatrix in="n" type="saturate" values="0"/>
    <feComponentTransfer><feFuncA type="linear" slope="0" intercept="1"/></feComponentTransfer>
  </filter>
  <filter id="blur40"><feGaussianBlur stdDeviation="40"/></filter>
  <filter id="gray"><feColorMatrix type="saturate" values="0"/></filter>
`;

// Light from the top left, falling off to the bottom right.
const RIM_MASK = `
  ${lin("rimFade", [[0, "#fff", 1], [0.45, "#fff", 0.55], [1, "#fff", 0.12]], 0, 0, 1, 1)}
  <mask id="rimMask" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
    <rect width="1024" height="1024" fill="url(#rimFade)"/>
  </mask>`;

/** One Liquid Glass element: lift shadow, body, inner glow, specular rim, sheen. */
function glassPiece(id, shape, { top, bottom, opacity = 0.94, glow = 0.35, rim = 0.95, sheen = 0.32 }) {
  return {
    defs: `${lin(`${id}Body`, [[0, top], [1, bottom]])}
      <mask id="${id}Clip" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">${shape("#fff")}</mask>`,
    body: `
      <g filter="url(#lift)">${shape("#000")}</g>
      <g filter="url(#contact)">${shape("#000")}</g>
      <g opacity="${opacity}">${shape(`url(#${id}Body)`)}</g>
      <g opacity="${glow}" filter="url(#innerGlow)">${shape("#fff")}</g>
      <g mask="url(#${id}Clip)" opacity="${sheen}">
        <ellipse cx="330" cy="150" rx="520" ry="300" fill="#fff" filter="url(#blur40)"/>
      </g>
      <g mask="url(#rimMask)" opacity="${rim}"><g filter="url(#rim)">${shape("#fff")}</g></g>`,
  };
}

const fillL = (p) => shapeL(`fill="${p}"`);

const GLASS = {
  light: {
    bg: [[0, "#FFFFFF"], [1, "#F6E8EB"]], glowBg: "#F3C3CC",
    L: { top: "#E2425E", bottom: "#8C0F27", opacity: 0.97, glow: 0.22, sheen: 0.26 },
    D: { top: "#5E1424", bottom: "#2A050D", opacity: 1, glow: 0.12, sheen: 0.2 },
  },
  dark: {
    bg: null, // transparent: the system lays its own dark backdrop under it
    L: { top: "#FF6E84", bottom: "#A0132E", opacity: 0.92, glow: 0.42 },
    D: { top: "#FFFFFF", bottom: "#EBD3D8", glow: 0.1 },
  },
  tinted: {
    bg: null,
    L: { top: "#E6E6E6", bottom: "#8E8E8E", glow: 0.3 },
    D: { top: "#FFFFFF", bottom: "#E2E2E2", glow: 0.08 },
    gray: true,
  },
  "clear-light": {
    bg: null,
    L: { top: "#FFFFFF", bottom: "#FFFFFF", opacity: 0.38, glow: 0.55, sheen: 0.4 },
    D: { top: "#FFFFFF", bottom: "#FFFFFF", opacity: 0.62, glow: 0.4 },
  },
  "clear-dark": {
    bg: null,
    L: { top: "#FFFFFF", bottom: "#FFFFFF", opacity: 0.2, glow: 0.45, sheen: 0.25 },
    D: { top: "#FFFFFF", bottom: "#FFFFFF", opacity: 0.45, glow: 0.3 },
  },
};

export function glass(mode = "light") {
  const s = GLASS[mode];
  const L = glassPiece("gL", fillL, s.L);
  const D = glassPiece("gD", shapeDownload, s.D);
  let defs = FILTERS + RIM_MASK + L.defs + D.defs;
  let bg = "";
  if (s.bg) {
    defs += lin("bg", s.bg) + rad("bgGlow", 0.82, 0.92, 0.75, [[0, s.glowBg, 0.75], [1, s.glowBg, 0]]);
    bg = `<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#bgGlow)"/>`;
  }
  const art = `${L.body}${D.body}`;
  return svg(bg + (s.gray ? `<g filter="url(#gray)">${art}</g>` : art), defs);
}

// ---------------------------------------------------------------- iOS 6 ----

const IOS6 = {
  light: {
    bg: [[0, "#F7F4F4"], [0.55, "#E2DCDD"], [1, "#BDB3B5"]], linen: 0.14,
    L: [[0, "#FF8FA0"], [0.48, "#D42444"], [0.52, "#B5152F"], [1, "#7A0A1E"]], Lstroke: "#560615",
    D: [[0, "#5E656C"], [0.5, "#2B3035"], [1, "#0E1012"]], Dstroke: "#000",
    emboss: true, gloss: 0.7,
  },
  dark: {
    bg: [[0, "#4A4E52"], [0.5, "#2B2E31"], [1, "#121415"]], linen: 0.12,
    L: [[0, "#FF9DAD"], [0.48, "#E5304F"], [0.52, "#C21C38"], [1, "#840C22"]], Lstroke: "#3A040E",
    D: [[0, "#FFFFFF"], [0.5, "#DDE3E7"], [0.52, "#C3CBD1"], [1, "#8E989F"]], Dstroke: "#2E3337",
    emboss: false, gloss: 0.38,
  },
  tinted: {
    bg: null, linen: 0,
    L: [[0, "#F2F2F2"], [0.48, "#BDBDBD"], [0.52, "#A8A8A8"], [1, "#7A7A7A"]], Lstroke: "#4A4A4A",
    D: [[0, "#FFFFFF"], [1, "#DADADA"]], Dstroke: "#6A6A6A",
    emboss: false, gloss: 0.3, gray: true,
  },
};

// The iOS 6 highlight: a bright arc over the top half, curving down at the sides.
const GLOSS_PATH = "M0,0 H1024 V418 C770,520 254,520 0,418 Z";

export function ios6(mode = "light") {
  const s = IOS6[mode];
  let defs = FILTERS +
    lin("i6L", s.L) + lin("i6D", s.D) +
    lin("gloss", [[0, "#fff", 0.95], [0.55, "#fff", 0.42], [1, "#fff", 0.26]]) +
    lin("edge", [[0, "#fff", 0.9], [0.08, "#fff", 0], [0.92, "#000", 0], [1, "#000", 0.35]]);
  let bg = "";
  if (s.bg) {
    defs += lin("i6bg", s.bg) + rad("vignette", 0.5, 0.45, 0.75, [[0.6, "#000", 0], [1, "#000", 0.22]]);
    bg = `<rect width="1024" height="1024" fill="url(#i6bg)"/>
      <rect width="1024" height="1024" filter="url(#linen)" opacity="${s.linen}" style="mix-blend-mode:multiply"/>
      <rect width="1024" height="1024" fill="url(#vignette)"/>`;
  }
  const L = `
    <g filter="url(#drop6)">${fillL("#000")}</g>
    ${fillL(`url(#i6L)`)}
    <path d="${L_PATH}" fill="none" stroke="${s.Lstroke}" stroke-width="7" stroke-opacity="0.85"/>
    <g opacity="0.45" filter="url(#innerShadow)">${fillL("#000")}</g>
    <g opacity="0.9" filter="url(#innerHighlight)">${fillL("#000")}</g>`;
  const arrowOutline = (w, c, o = 1) =>
    `<path d="${ARROW_PATH}" fill="none" stroke="${c}" stroke-opacity="${o}" stroke-width="${ARROW.width + w}" stroke-linecap="round" stroke-linejoin="round"/>` +
    `<path d="${TRAY_PATH}" fill="none" stroke="${c}" stroke-opacity="${o}" stroke-width="${w}"/>`;
  const D = `
    ${s.emboss ? `<g filter="url(#emboss)">${shapeDownload("#000")}</g>` : `<g filter="url(#drop6)">${shapeDownload("#000")}</g>`}
    ${arrowOutline(7, s.Dstroke, 0.9)}
    ${shapeDownload("url(#i6D)")}
    <g opacity="0.5" filter="url(#innerShadow)">${shapeDownload("#000")}</g>
    <g opacity="${mode === "light" ? 0.55 : 0.9}" filter="url(#innerHighlight)">${shapeDownload("#000")}</g>`;
  const top = `
    <path d="${GLOSS_PATH}" fill="url(#gloss)" opacity="${s.gloss}"/>
    ${s.bg ? `<rect x="3" y="3" width="1018" height="1018" fill="none" stroke="url(#edge)" stroke-width="6"/>` : ""}`;
  const art = `${L}${D}${top}`;
  return svg(bg + (s.gray ? `<g filter="url(#gray)">${art}</g>` : art), defs);
}

// ------------------------------------------------ Icon Composer layers ----

/** Plain white layers for AppIcon.icon: Icon Composer fills and lights them. */
export function layer(name) {
  const body = {
    Letter: shapeL(`fill="#fff"`),
    Arrow: shapeArrow("#fff"),
    Tray: shapeTray(`fill="#fff"`),
  }[name];
  return svg(body);
}

// ------------------------------------------------------ in-app tool tiles ----

import { TOOLS, TOOL_DEFS } from "./tools.mjs";

/** A tool tile (tools.mjs) in the icon's glass design: light or dark. */
export function toolTile(name, mode = "light") {
  const dark = mode === "dark";
  const piece = glassPiece("tool", TOOLS[name], dark
    ? { top: "#FF7D92", bottom: "#B0173A", opacity: 0.95, glow: 0.38, sheen: 0.24 }
    : { top: "#E2425E", bottom: "#8C0F27", opacity: 0.97, glow: 0.22, sheen: 0.26 });
  const bg = dark ? [[0, "#3A1018"], [1, "#12040A"]] : [[0, "#FFFFFF"], [1, "#F6E8EB"]];
  const glow = dark ? "#7A1426" : "#F3C3CC";
  const defs = FILTERS + RIM_MASK + TOOL_DEFS + piece.defs + lin("tbg", bg) +
    rad("tglow", 0.82, 0.92, 0.75, [[0, glow, 0.7], [1, glow, 0]]);
  return svg(`<rect width="1024" height="1024" fill="url(#tbg)"/><rect width="1024" height="1024" fill="url(#tglow)"/>${piece.body}`, defs);
}
