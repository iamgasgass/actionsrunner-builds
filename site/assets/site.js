// iLoader X site: menu, reveal on scroll, English / Italian, copy buttons,
// install links, the latest version and the phone's run. Written for iLoader X.
(() => {
  "use strict";
  const REPO = "iamgasgass/iLoaderX";
  const base = new URL(".", location.href).href;
  const SOURCE = base + "iloaderx.json";
  const IPA = `https://github.com/${REPO}/releases/latest/download/iLoaderX.ipa`;
  const TIPA = `https://github.com/${REPO}/releases/latest/download/iLoaderX.tipa`;
  const enc = encodeURIComponent;
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

  // ---- language -----------------------------------------------------------
  const IT = window.ILOADERX_IT || {};
  const originals = new Map();
  $$("[data-i18n]").forEach((el) => originals.set(el, el.innerHTML));
  let lang = "en";
  try { lang = localStorage.getItem("lang") || ""; } catch {}
  if (lang !== "en" && lang !== "it") lang = (navigator.language || "").toLowerCase().startsWith("it") ? "it" : "en";
  const t = (key, en) => (lang === "it" && IT[key]) || en;

  function applyLang() {
    document.documentElement.lang = lang;
    originals.forEach((en, el) => { el.innerHTML = lang === "it" && IT[el.dataset.i18n] ? IT[el.dataset.i18n] : en; });
    $$("[data-i18n-attr]").forEach((el) => {
      const [attr, key] = el.dataset.i18nAttr.split(":");
      if (!el.dataset.en) el.dataset.en = el.getAttribute(attr) || "";
      el.setAttribute(attr, t(key, el.dataset.en));
    });
    $$(".lang button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.lang === lang)));
    showVersion();
  }
  $$(".lang button").forEach((b) => b.addEventListener("click", () => {
    lang = b.dataset.lang;
    try { localStorage.setItem("lang", lang); } catch {}
    applyLang();
  }));

  // ---- menu ---------------------------------------------------------------
  const menu = document.querySelector(".nav-menu");
  const links = document.getElementById("navLinks");
  if (menu && links) {
    const set = (open) => { links.classList.toggle("open", open); menu.setAttribute("aria-expanded", String(open)); };
    menu.addEventListener("click", (e) => { e.stopPropagation(); set(!links.classList.contains("open")); });
    document.addEventListener("click", (e) => { if (!links.contains(e.target)) set(false); });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") set(false); });
    links.addEventListener("click", (e) => { if (e.target.closest("a")) set(false); });
  }
  const here = location.pathname.split("/").pop() || "index.html";
  $$(".nav-links a").forEach((a) => { if (a.getAttribute("href") === here) a.setAttribute("aria-current", "page"); });

  // ---- install links ------------------------------------------------------
  const hrefs = {
    sidestore: "sidestore://source?url=" + enc(SOURCE),
    altstore: "altstore://source?url=" + enc(SOURCE),
    livecontainer: "livecontainer://install?url=" + enc(IPA),
    trollstore: "apple-magnifier://install?url=" + enc(TIPA),
    ipa: IPA,
    tipa: TIPA,
    source: SOURCE,
  };
  $$("[data-href]").forEach((a) => { if (hrefs[a.dataset.href]) a.href = hrefs[a.dataset.href]; });
  $$("[data-text]").forEach((el) => { if (hrefs[el.dataset.text]) el.textContent = hrefs[el.dataset.text]; });

  // ---- copy ---------------------------------------------------------------
  $$("[data-copy]").forEach((btn) => btn.addEventListener("click", async () => {
    const target = btn.dataset.copy ? document.getElementById(btn.dataset.copy) : btn.previousElementSibling;
    const text = target ? target.textContent.trim() : "";
    try { await navigator.clipboard.writeText(text); } catch {
      const r = document.createRange(); r.selectNodeContents(target);
      const s = getSelection(); s.removeAllRanges(); s.addRange(r);
      try { document.execCommand("copy"); } catch {}
    }
    const label = btn.textContent;
    btn.textContent = t("copied", "Copied"); btn.classList.add("done");
    setTimeout(() => { btn.textContent = label; btn.classList.remove("done"); }, 1500);
  }));

  // ---- version ------------------------------------------------------------
  let version = null; // null: loading, "": none
  function showVersion() {
    $$("[data-version]").forEach((el) => {
      el.textContent = version ? t("version", "Version") + " " + version : version === "" ? t("noRelease", "No release yet") : "…";
    });
  }
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject()))
    .then((r) => { version = String(r.tag_name || "").replace(/^v/i, ""); })
    .catch(() => fetch(SOURCE).then((r) => r.json()).then((s) => { version = s.apps[0].version || ""; }).catch(() => { version = ""; }))
    .finally(showVersion);

  // ---- install page tabs --------------------------------------------------
  const tabs = $$("[role=tab]");
  function openTab(id, push) {
    tabs.forEach((b) => {
      const on = b.getAttribute("aria-controls") === id;
      b.setAttribute("aria-selected", String(on));
      const panel = document.getElementById(b.getAttribute("aria-controls"));
      if (panel) panel.hidden = !on;
    });
    if (push) history.replaceState(null, "", "#" + id);
  }
  tabs.forEach((b) => b.addEventListener("click", () => openTab(b.getAttribute("aria-controls"), true)));
  if (tabs.length) {
    const wanted = location.hash.slice(1);
    openTab(tabs.some((b) => b.getAttribute("aria-controls") === wanted) ? wanted : tabs[0].getAttribute("aria-controls"), false);
  }
  // A link to a question opens it.
  const q = location.hash && document.getElementById(location.hash.slice(1));
  if (q && q.tagName === "DETAILS") q.open = true;

  // ---- reveal -------------------------------------------------------------
  const io = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
  }, { rootMargin: "0px 0px -8% 0px" }) : null;
  $$("[data-reveal]").forEach((el) => (io ? io.observe(el) : el.classList.add("in")));

  // How it works: the step in the middle of the screen lights up.
  const steps = $$(".steps.live > li");
  if (steps.length && "IntersectionObserver" in window) {
    const so = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) { steps.forEach((s) => s.classList.toggle("on", s === e.target)); }
    }), { rootMargin: "-45% 0px -45% 0px" });
    steps.forEach((s) => so.observe(s));
  }

  // ---- the phone's run ----------------------------------------------------
  const pct = document.querySelector(".ph-run-head span");
  const stepEl = document.querySelector(".ph-step");
  if (pct && stepEl && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
    const names = [
      ["ph.s1", "Connecting LocalDevVPN"], ["ph.s2", "Signing in"], ["ph.s3", "Pairing this iPhone"],
      ["ph.s4", "Downloading SideStore"], ["ph.s5", "Signing"], ["ph.s6", "Installing"], ["ph.s7", "Done"],
    ];
    const start = performance.now();
    const tick = (now) => {
      const p = Math.min(1, ((now - start) % 7000) / 5600);
      const eased = p < .5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
      pct.textContent = Math.round(eased * 100) + "%";
      const [key, en] = names[Math.min(names.length - 1, Math.floor(eased * (names.length - 1) + .001))];
      stepEl.textContent = t(key, en);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  applyLang();
})();
