// The Lip Service 1.0.6 bar, drawn to the app's numbers: BarStyle and the views in Bar.swift, HalftonePrint.swift and
// HaloGlow.swift. Sizes are points times --s. Everything is a function of the arguments, so a seeked frame always draws the same.
// The glyph is the halftone print: white dots on a 45-degree screen, the voice entering at the left and running right into
// the words. While the words are finished, or an agent is working, it settles to a thin line with a light running along it.
// Around the capsule, while listening, the halo: blue dots on a hex grid lit by the voice, the light spreading out from the print.
// Site copy: adds the page's fallback font, and el.maxW (pt) so a bar fits a phone screen.
const GLYPH_W = 45, PAD = 18, GAP = 13, AVATAR = 22, BAR_H = 40, MAX_W = 560;
const HALO_MARGIN = 26 + 2;
const UI_FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter LS', system-ui, sans-serif";
const SVGNS = "http://www.w3.org/2000/svg";
const PRINT = []; {
  const d = 2.6, cx = d / Math.SQRT2, ry = d * Math.SQRT2;
  for (let ci = 0, x = 1.5; x <= GLYPH_W - 1.5; ci++, x = 1.5 + ci * cx) {
    const off = ci % 2 ? ry / 2 : 0;
    for (let y = off - Math.ceil(10 / ry) * ry; y <= 10; y += ry) if (Math.abs(y) <= 9.6) PRINT.push({ x, y });
  }
}

// HaloGlow.dots: the grid for one capsule size, cached by width.
const HALO_GRIDS = new Map();
function haloDots(w) {
  const key = Math.round(w * 2) / 2;
  if (HALO_GRIDS.has(key)) return HALO_GRIDS.get(key);
  const h = BAR_H, radius = h / 2, printX = PAD + GLYPH_W / 2, printY = radius, dots = [];
  for (let row = 0, y = -26; y <= h + 26; row++, y = -26 + row * 5 * 0.866) {
    const shift = row % 2 ? 2.5 : 0;
    for (let col = 0, x = -26 + shift; x <= key + 26; col++, x = -26 + shift + col * 5) {
      const edge = Math.hypot(Math.max(radius - x, 0, x - (key - radius)), y - printY) - radius;
      if (edge < 2 || edge > 26) continue;
      const far = Math.hypot(x - printX, 1.6 * (y - printY));
      const weight = Math.exp(-(((edge - 2) / 11) ** 2)) * Math.exp(-far / 520);
      if (weight >= 0.015) dots.push({ x, y, delay: far / 900, weight });
    }
  }
  HALO_GRIDS.set(key, dots);
  return dots;
}

function makeBar({ words = "", agent = null, res = 1 } = {}) {
  const el = document.createElement("div");
  el.className = "lsbar";
  el.res = res;
  el.halo = document.createElement("canvas"); el.halo.className = "halo";
  const cap = document.createElement("div"); cap.className = "capsule";
  if (agent) {
    const chip = document.createElement("div"); chip.className = "agent";
    chip.innerHTML = `<span class="av">${agent.slice(0, 1)}</span><span class="nm">${agent}</span>`;
    cap.append(chip);
  }
  el.agentW = agent ? AVATAR + 8 + measureText(agent, `600 13px ${UI_FONT}`) + GAP : 0;
  const svg = document.createElementNS(SVGNS, "svg");
  svg.setAttribute("class", "glyph"); svg.setAttribute("viewBox", `0 -10.5 ${GLYPH_W} 21`);
  el.dots = PRINT.map(p => {
    const c = document.createElementNS(SVGNS, "circle");
    c.setAttribute("cx", p.x.toFixed(3)); c.setAttribute("cy", p.y.toFixed(3)); c.setAttribute("fill", "#F4F4F5"); c.setAttribute("opacity", "0.96"); svg.append(c);
    return { c, ...p };
  });
  const w = document.createElement("div"); w.className = "words";
  const track = document.createElement("span"); track.className = "track"; w.append(track);
  const st = document.createElement("div"); st.className = "status";
  cap.append(svg, w, st);
  el.append(el.halo, cap);
  el.cap = cap;
  setBar(el, { words });
  return el;
}

// env(delay) is the voice level `delay` seconds ago, 0 to 1. spin is how far into finishing (0 to 1), at time t.
// still: an agent waiting on the user, drawn as the dim baseline with no light moving along it.
const sstep = x => x * x * (3 - 2 * x);
const clamp01 = x => Math.min(1, Math.max(0, x));
function setGlyph(el, env = () => 0, spin = 0, t = 0, still = false) {
  const pass = ((t * 1.5) % 1) * 58 - 7;
  for (const p of el.dots) {
    const a = env(p.x / 70), h = 1.0 + 8.2 * a, yy = Math.abs(p.y);
    const arrive = 1 - 0.85 * sstep(clamp01((p.x - 31) / 14));
    let s = sstep(clamp01((h - yy) / 3 + 0.5)) * (1 - 0.6 * Math.min(1, yy / Math.max(h, 1))) * arrive;
    if (spin > 0.001) {
      const line = 0.16 * Math.exp(-p.y * p.y / 3);
      s = Math.max(s * (1 - spin), spin * (still ? line : Math.max(line, 0.7 * Math.exp(-((p.x - pass) ** 2) / 28 - p.y * p.y / 10))));
    }
    const r = Math.sqrt(s);
    p.c.setAttribute("r", r > 0.14 ? r.toFixed(3) : "0");
  }
}

// glow(delay) lights the halo; light is how far it has faded in (0 to 1). Each frame sorts the lit dots into 24 shades
// by opacity and fills each shade once, as HaloView does.
function drawHalo(el, glow, light) {
  const cv = el.halo, s = parseFloat(el.style.getPropertyValue("--s")) || 1, k = s * el.res, M = HALO_MARGIN;
  const w = el.cap.offsetWidth / s;
  const cw = Math.ceil((w + 2 * M) * k), ch = Math.ceil((BAR_H + 2 * M) * k);
  if (cv.width !== cw || cv.height !== ch) { cv.width = cw; cv.height = ch; cv.style.width = cw / el.res + "px"; cv.style.height = ch / el.res + "px"; }
  const g = cv.getContext("2d");
  g.clearRect(0, 0, cw, ch);
  if (!(light > 0.004)) return;
  const shades = 24, step = 0.62 / (shades - 1), paths = [];
  for (const d of haloDots(w)) {
    const st = (0.12 + 0.88 * glow(d.delay)) * d.weight;
    if (st < 0.015) continue;
    const r = (0.4 + 1.1 * st) * k, x = (M + d.x) * k, y = (M + d.y) * k;
    const i = Math.min(shades - 1, Math.round(0.62 * st / step));
    (paths[i] ??= new Path2D()).moveTo(x + r, y);
    paths[i].arc(x, y, r, 0, 2 * Math.PI);
  }
  paths.forEach((p, i) => { if (p) { g.fillStyle = `rgba(90,132,240,${((0.05 + i * step) * light).toFixed(4)})`; g.fill(p); } });
}

// Listening or finishing: words, with ages[i] how long word i has been showing, and grow easing the words' column from the
// width of prevWords. Working: status set, the agent's line in grey after the print. fromW (pt) eases the content's
// width from the last state's, so the capsule grows or shrinks as the app animates it.
function setBar(el, { words = "", ages, env, spin = 0, t = 0, prevWords, grow = 1, status, still = false, glow, light = 0, fromW }) {
  const working = status != null;
  setGlyph(el, working ? () => 0 : env, working ? 1 : spin, t, still);
  const box = el.cap.querySelector(".words"), track = box.firstChild, st = el.cap.querySelector(".status");
  st.style.display = working ? "block" : "none";
  box.style.display = !working && words ? "flex" : "none";
  if (working) {
    if (st.textContent !== status) st.textContent = status;
    const natural = measureText(status, `500 13px ${UI_FONT}`);
    st.style.width = `calc(${(fromW == null ? natural : fromW + (natural - fromW) * grow).toFixed(2)}px * var(--s))`;
  } else {
    const list = words ? words.split(" ") : [];
    if (track.dataset.words !== words) {
      track.innerHTML = "";
      list.forEach((x, i) => { if (i) track.append(" "); const s = document.createElement("span"); s.className = "w"; s.textContent = x; track.append(s); });
      track.dataset.words = words;
    }
    // Each new word prints in through a dot screen: 3 pt cells whose dots grow from nothing to full over 0.55 s.
    [...track.children].forEach((s, i) => {
      const u = ages ? Math.min(1, Math.max(0, ages[i] ?? 1) / 0.55) : 1, p = 1 - Math.pow(1 - u, 3);
      s.style.opacity = (0.5 + 0.5 * p).toFixed(3);
      s.style.setProperty("--dot", `calc(${(2.4 * p).toFixed(3)}px * var(--s))`);
      s.classList.toggle("printing", p < 0.999);
      if (u === 0) s.style.opacity = "0";
    });
    if (words) {
      const room = (el.maxW || MAX_W) - PAD - el.agentW - GLYPH_W - PAD - GAP;
      const natural = Math.min(textWidth(words), room);
      const from = fromW ?? (prevWords ? Math.min(textWidth(prevWords), room) : natural);
      box.style.width = `calc(${(from + (natural - from) * grow + 1).toFixed(2)}px * var(--s))`;
      box.classList.toggle("over", textWidth(words) > room);
    }
  }
  drawHalo(el, glow ?? (() => 0), light);
}

// The width the content takes in a state, in points, for fromW.
function contentWidth(el, { words, status }) {
  if (status != null) return measureText(status, `500 13px ${UI_FONT}`);
  return words ? Math.min(textWidth(words), (el.maxW || MAX_W) - PAD - el.agentW - GLYPH_W - PAD - GAP) + 1 : 0;
}

const MEASURE = document.createElement("canvas").getContext("2d");
function measureText(text, font) { MEASURE.font = font; return MEASURE.measureText(text).width; }
// Width in points at 15 pt, measured once per string in the bar's own font.
const TEXT_W = new Map();
function textWidth(text) {
  if (TEXT_W.has(text)) return TEXT_W.get(text);
  const m = document.createElement("span");
  m.style.cssText = `position:absolute;visibility:hidden;white-space:nowrap;font-size:15px;font-family:${UI_FONT};word-spacing:0`;
  m.textContent = text; document.body.append(m);
  const w = m.getBoundingClientRect().width; m.remove();
  if (document.fonts.status === "loaded") TEXT_W.set(text, w);
  return w;
}
