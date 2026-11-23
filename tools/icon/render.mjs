// Renders every iLoader X icon master to PNG, writes the Icon Composer
// layers, and draws the preview sheet.
//
//   node tools/icon/render.mjs <out-dir>
//
// Then tools/icon/build_assets.py cuts the asset-catalog sizes from the masters.
// Needs Playwright with Chromium (require('playwright')).

import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { glass, ios6, layer, toolTile } from "./styles.mjs";
import { TOOLS } from "./tools.mjs";
import { squirclePath } from "./glyph.mjs";

const out = process.argv[2] ?? "build/icon";
mkdirSync(out, { recursive: true });

const masters = {
  "glass-light": glass("light"),
  "glass-dark": glass("dark"),
  "glass-tinted": glass("tinted"),
  "glass-clear-light": glass("clear-light"),
  "glass-clear-dark": glass("clear-dark"),
  "ios6-light": ios6("light"),
  "ios6-dark": ios6("dark"),
  "ios6-tinted": ios6("tinted"),
};
for (const name of ["Letter", "Arrow", "Tray"]) writeFileSync(join(out, `layer-${name}.svg`), layer(name));
for (const [name, doc] of Object.entries(masters)) writeFileSync(join(out, `${name}.svg`), doc);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });

async function shot(html, file, w = 1024, h = 1024) {
  await page.setViewportSize({ width: w, height: h });
  await page.setContent(`<!doctype html><html><body style="margin:0;background:transparent">${html}</body></html>`);
  await page.screenshot({ path: file, omitBackground: true, clip: { x: 0, y: 0, width: w, height: h } });
}
for (const [name, doc] of Object.entries(masters)) await shot(doc, join(out, `${name}.png`));
const tools = {};
for (const name of Object.keys(TOOLS)) for (const mode of ["light", "dark"]) {
  tools[`${name}-${mode}`] = toolTile(name, mode);
  await shot(tools[`${name}-${mode}`], join(out, `tool-${name}-${mode}.png`));
}

// ---- preview sheet: each variant as iOS shows it, masked, on its backdrop.
const enc = (s) => "data:image/svg+xml;base64," + Buffer.from(s).toString("base64");
const sq = squirclePath(1024);
const tile = (svgDoc, backdrop, label, sub, tint) => `
  <figure>
    <div class="wall" style="background:${backdrop}">
      <svg viewBox="0 0 1024 1024" width="188" height="188">
        <defs><clipPath id="c${label.replace(/\W/g, "")}${sub.replace(/\W/g, "")}"><path d="${sq}"/></clipPath></defs>
        <g clip-path="url(#c${label.replace(/\W/g, "")}${sub.replace(/\W/g, "")})">
          ${tint ? `<rect width="1024" height="1024" fill="${tint.bg}"/>` : ""}
          <image href="${enc(svgDoc)}" width="1024" height="1024" ${tint ? `style="filter:${tint.filter}"` : ""}/>
          ${tint && tint.color ? `<rect width="1024" height="1024" fill="${tint.color}" style="mix-blend-mode:multiply"/>` : ""}
        </g>
        <path d="${sq}" fill="none" stroke="rgba(255,255,255,.18)" stroke-width="6"/>
      </svg>
    </div>
    <figcaption><b>${label}</b><span>${sub}</span></figcaption>
  </figure>`;
const darkSys = "radial-gradient(120% 120% at 30% 20%, #2b2f33, #050607)";
const wallLight = "linear-gradient(160deg,#9fd8ff,#ffd3e8 55%,#ffe9b0)";
const wallDark = "linear-gradient(160deg,#0b1b2e,#2a1031 60%,#0d0d10)";
const sysDarkBg = "linear-gradient(180deg,#303336,#0b0c0d)";
const tintBg = "linear-gradient(180deg,#2a1d20,#080505)";
const tintFilter = "grayscale(1) brightness(1.15)";
const frosted = (c) => `linear-gradient(180deg,${c})`;

const sheet = `
<style>
  body{font:15px -apple-system,"SF Pro Text","Helvetica Neue",Inter,Arial,sans-serif;color:#e8ecef;background:#0e1012}
  .sheet{width:1600px;padding:48px 56px;box-sizing:border-box;background:#0e1012}
  h1{font-size:34px;margin:0 0 4px;font-weight:700;letter-spacing:-.4px}
  h2{font-size:19px;margin:36px 0 16px;font-weight:600;color:#ff9aab}
  p{margin:0;color:#97a1a8}
  .row{display:flex;gap:22px;flex-wrap:wrap}
  figure{margin:0;width:262px}
  .wall{height:262px;border-radius:26px;display:flex;align-items:center;justify-content:center}
  figcaption{margin-top:10px;display:flex;flex-direction:column;gap:2px}
  figcaption span{color:#8a949b;font-size:13px}
</style>
<div class="sheet">
  <h1>iLoader X — app icon</h1>
  <p>com.iamgasgass.iloaderx · glyph redrawn from scratch: rounded “L”, download arrow landing on a tray</p>
  <h2>Liquid Glass — primary icon (AppIcon.icon on iOS 26+, AppIcon.appiconset on iOS 17.4–25)</h2>
  <div class="row">
    ${tile(masters["glass-light"], wallLight, "Default", "light")}
    ${tile(masters["glass-dark"], wallDark, "Dark", "system dark backdrop", { bg: sysDarkBg, filter: "none" })}
    ${tile(masters["glass-clear-light"], wallLight, "Clear", "light", { bg: "rgba(255,255,255,.28)", filter: "none" })}
    ${tile(masters["glass-clear-dark"], wallDark, "Clear", "dark", { bg: "rgba(20,20,24,.55)", filter: "none" })}
    ${tile(masters["glass-tinted"], wallDark, "Tinted", "red tint, dark", { bg: tintBg, filter: tintFilter, color: "#FF5A72" })}
  </div>
  <h2>In-app tool tiles (light / dark)</h2>
  <div class="row">
    ${Object.keys(TOOLS).map((n) => tile(tools[n + "-light"], "#e9e4e5", n.replace("Logo", ""), "light")).join("")}
  </div>
  <div class="row" style="margin-top:22px">
    ${Object.keys(TOOLS).map((n) => tile(tools[n + "-dark"], "#14070a", n.replace("Logo", ""), "dark")).join("")}
  </div>
  <h2>iOS 6 — alternate icon “AppIcon-iOS6” (Settings › App Icon)</h2>
  <div class="row">
    ${tile(masters["ios6-light"], "#4c5a63 url('') ", "Default", "light")}
    ${tile(masters["ios6-dark"], wallDark, "Dark", "iOS 18+")}
    ${tile(masters["ios6-tinted"], wallDark, "Tinted", "red tint, iOS 18+", { bg: tintBg, filter: tintFilter, color: "#FF5A72" })}
  </div>
</div>`;
await page.setViewportSize({ width: 1600, height: 900 });
await page.setContent(`<!doctype html><html><body style="margin:0">${sheet}</body></html>`);
const h = await page.evaluate(() => document.querySelector(".sheet").getBoundingClientRect().height);
await page.setViewportSize({ width: 1600, height: Math.ceil(h) });
await page.screenshot({ path: join(out, "preview.png"), clip: { x: 0, y: 0, width: 1600, height: Math.ceil(h) } });

await browser.close();
console.log("rendered to", out);
