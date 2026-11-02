// The page borrows the launch video's parts (launch.html): the halftone camera, the word-by-word captions, the bar,
// the square confetti and its scenes. Each scene draws itself from a time, as the video's RUN functions do, so a
// frame never depends on the last one. bar.js (makeBar, setBar, drawHalo, contentWidth) loads first as a classic script.
import { createField } from "./field.js";

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const clamp = x => Math.max(0, Math.min(1, x));
const seg = (t, a, b) => clamp((t - a) / (b - a));
const out3 = x => 1 - Math.pow(1 - x, 3);
const inOut = x => x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
const outBack = x => { const c = 1.9; return 1 + (c + 1) * Math.pow(x - 1, 3) + c * Math.pow(x - 1, 2); };
const lerp = (a, b, p) => a + (b - a) * p;
const rnd = n => { const x = Math.sin(n * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); };
const quad = (u, a, c, b) => (1 - u) * (1 - u) * a + 2 * (1 - u) * u * c + u * u * b;
const COLORS = ["#2F6BFF", "#FF3EA5", "#16C65B", "#8B5CF6", "#FF9F0A"];
const arrow = fill => `<svg viewBox="0 0 32 32"><path d="M5 4 L27 12.5 L16.5 15.8 L12.8 26.8 Z" fill="${fill}" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const narrow = () => innerWidth < 700;
const barRes = () => Math.min(devicePixelRatio || 1, 2);
const now = () => performance.now() / 1000;

// ---------- the download link and the install prompt. A release changes DOWNLOAD_URL only; the HTML keeps the same href for no-JS. ----------
const DOWNLOAD_URL = "https://github.com/hunterbohm/lip-service/releases/download/v1.0.8/Lip-Service-1.0.8.zip";
$$("a[data-download]").forEach(a => { a.href = DOWNLOAD_URL; });

(() => {
  const pre = $("#prompt"), wrap = pre.parentElement, more = $(".more", wrap), status = $("#copy-status");
  const buttons = $$("[data-copy]");
  const timers = new Map();
  // The prompt shows 8 lines with a fade; the toggle only appears when the text is taller than that.
  if (pre.scrollHeight > pre.clientHeight + 4) more.hidden = false; else wrap.dataset.collapsed = "false";
  const expand = open => {
    wrap.dataset.collapsed = String(!open);
    more.setAttribute("aria-expanded", String(open));
    $(".t", more).textContent = open ? "Show less" : "Show all";
  };
  more.addEventListener("click", () => expand(wrap.dataset.collapsed === "true"));

  function selectPrompt() {
    expand(true);
    const range = document.createRange(); range.selectNodeContents(pre);
    const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range);
    try { return document.execCommand("copy") ? "copied" : "selected"; } catch { return "selected"; }
  }
  async function copy() {
    try { await navigator.clipboard.writeText(pre.textContent); return "copied"; } catch {}
    return selectPrompt();
  }
  const MSG = { copied: "Copied. Paste it into Claude Code or Codex.", selected: "Selected. Press ⌘C to copy it." };
  buttons.forEach(btn => btn.addEventListener("click", async () => {
    const state = await copy();
    if (state === "selected" && !btn.closest("#install")) $("#install").scrollIntoView({ block: "center", behavior: reduced ? "auto" : "smooth" });
    $(".done", btn).textContent = MSG[state];
    status.textContent = ""; requestAnimationFrame(() => { status.textContent = MSG[state]; });
    btn.dataset.state = state;
    clearTimeout(timers.get(btn));
    timers.set(btn, setTimeout(() => { delete btn.dataset.state; }, 4500));
  }));
})();

function pop(el, t, a, dur = .45, from = .9, dy = 24) {
  const p = out3(seg(t, a, a + dur));
  el.style.opacity = p;
  el.style.transform = (el.dataset.base || "") + ` translateY(${(1 - p) * dy}px) scale(${lerp(from, 1, p)})`;
  el.style.filter = p < 1 ? `blur(${(1 - p) * 8}px)` : "none";
  return p;
}

// ---------- the voice, as launch.html's makeVoice: a swell per word update, run through the app's level envelope ----------
function makeVoice(press, release, updates, seed = 0) {
  const rate = 120, t0 = press - 1, n = Math.ceil((release - t0 + 3) * rate), env = new Float32Array(n), glow = new Float32Array(n);
  const k = tau => 1 - Math.exp(-1 / rate / tau);
  let v = 0, g = 0;
  for (let i = 0; i < n; i++) {
    const t = t0 + i / rate, since = t - press;
    let target = 0;
    if (since > .1 && t < release - .08) {
      updates.forEach(([u], j) => { const d = since - (u - .3), dur = .26 + .08 * rnd(seed + j + 3); if (d > 0 && d < dur) target = Math.max(target, (.62 + .38 * rnd(seed + j + 9)) * Math.pow(Math.sin(Math.PI * d / dur), .8)); });
      target *= .82 + .18 * Math.sin(t * 9.1) * Math.sin(t * 5.3);
    }
    v += (target - v) * k(target > v ? .05 : .1);
    g += (v - g) * k(v > g ? .12 : .35);
    env[i] = v; glow[i] = g;
  }
  const read = buf => (t, delay = 0) => { const f = (t - delay - t0) * rate, i = Math.floor(f), u = f - i; return i < 0 || i >= n - 1 ? 0 : buf[i] + (buf[i + 1] - buf[i]) * u; };
  const up = t => 1 - Math.exp(-Math.max(0, t - press) / .35);
  return { env: read(env), glow: read(glow), light: t => t < press ? 0 : t < release ? up(t) : up(release) * Math.exp(-(t - release) / .5) };
}
function wordsAt(text, updates, since) {
  const all = text.split(" "), ages = [];
  let n = 0, prev = 0, tu = -9;
  for (const [u, k] of updates) if (since >= u) { for (let i = n; i < k; i++) ages[i] = since - u; prev = n; n = k; tu = u; }
  return { words: all.slice(0, n).join(" "), prevWords: all.slice(0, prev).join(" "), grow: out3(seg(since, tu, tu + .35)), ages };
}

// ---------- square confetti bursting from a point ----------
function makeParts(host, n, seed) {
  return Array.from({ length: n }, (_, i) => {
    const el = document.createElement("i"), size = 6 + rnd(seed + i * 1.7) * 9;
    el.style.width = el.style.height = size + "px";
    el.style.background = COLORS[Math.floor(rnd(seed + i * 5.9) * COLORS.length)];
    el.style.borderRadius = size * .18 + "px";
    host.append(el);
    return { el, size, ang: rnd(seed + i * 3.1) * Math.PI * 2, sp: 420 + rnd(seed + i * 7.3) * 700, life: .7 + rnd(seed + i * 4.4) * .5 };
  });
}
function partsAt(ps, t, t0, cx, cy, rx, ry, scale) {
  for (const p of ps) {
    const e = t - t0;
    if (e < 0 || e > p.life) { p.el.style.opacity = 0; continue; }
    const q = e / p.life, dist = p.sp * (1 - Math.pow(1 - Math.min(e / .9, 1), 3)) * .55 * scale;
    p.el.style.opacity = 1 - q * q;
    p.el.style.transform = `translate(${cx + Math.cos(p.ang) * dist * rx - p.size / 2}px, ${cy + Math.sin(p.ang) * dist * ry - p.size / 2}px) rotate(${e * 260 * (p.ang > 3 ? 1 : -1)}deg) scale(${1 - q * .5})`;
  }
}

// ---------- captions: words blur in one by one (launch.html's makeCap), driven by CSS once the caption is on screen ----------
function splitWords(el) {
  let i = 0;
  (function walk(node) {
    for (const n of [...node.childNodes]) {
      if (n.nodeType === Node.TEXT_NODE) {
        const frag = document.createDocumentFragment();
        for (const part of n.textContent.split(/(\s+)/)) {
          if (!part) continue;
          if (/^\s+$/.test(part)) { frag.append(part); continue; }
          const s = document.createElement("span");
          s.className = "w"; s.style.setProperty("--i", i++); s.textContent = part; frag.append(s);
        }
        n.replaceWith(frag);
      } else if (n.nodeType === Node.ELEMENT_NODE && n.tagName !== "BR") walk(n);
    }
  })(el);
}
$$(".cap").forEach(splitWords);

// ---------- the camera: scrolling flies it forward through the field, and it keeps creeping when the page rests ----------
const field = createField($("#field"));
const CAM = { K: 1500, lz0: .35, creep: .012, drift: .35 };
const cam = { s: scrollY, y: 0, lz: CAM.lz0, drawn: -1, hist: [] };
const rings = [];
function ring(el, t0) { rings.push({ el, t0 }); }
function drawField(t, dt) {
  const s0 = cam.s;
  cam.s += (scrollY - cam.s) * (1 - Math.exp(-dt / .09));
  cam.lz = CAM.lz0 + cam.s / CAM.K + t * CAM.creep;
  cam.y += CAM.drift * (cam.s - s0) / Math.exp(cam.lz);
  cam.hist.push([t, cam.lz]);
  while (cam.hist.length > 2 && cam.hist[1][0] < t - .06) cam.hist.shift();
  const [ta, la] = cam.hist[0], [tb, lb] = cam.hist[1] ?? cam.hist[0];
  const prevLz = tb > ta ? lerp(la, lb, clamp((t - .06 - ta) / (tb - ta))) : la;
  const live = rings.filter(r => t >= r.t0 && t - r.t0 < 1.1).map(r => {
    const b = r.el.getBoundingClientRect();
    return { x: b.left + b.width / 2, y: b.top + b.height / 2, age: t - r.t0 };
  });
  const eb = $("#end").getBoundingClientRect(), L = .85 + .35 * clamp(1 - eb.top / innerHeight);
  // At rest the camera only creeps, so the field redraws about 15 times a second; scrolling or a ring redraws every frame.
  if (!live.length && Math.abs(cam.lz - cam.drawn) < 8e-4 && Math.abs(cam.lz - prevLz) < 8e-4) return;
  field.draw({ y: cam.y, lz: cam.lz }, prevLz, L, live);
  cam.drawn = cam.lz;
}

// ---------- hero: the payoff from the video's first frame. Hold the key and the bar prints the words; let go and they land ----------
const hero = (() => {
  const root = $("#demo"), card = $(".msg", root), typed = $(".typed", card), caret = $(".caret", card);
  const key = $(".key", root), took = $(".took", root), h1 = $("#headline");
  const bar = makeBar({ words: "", res: barRes() }); $(".barhost", root).append(bar);
  const parts = makeParts($(".particles", root), 46, 29);
  const D = { preview: "Running about ten minutes late, save me a seat", final: "Running about ten minutes late, save me a seat.",
    updates: [[.42, 1], [.72, 2], [1.0, 3], [1.3, 4], [1.62, 5], [1.95, 7], [2.22, 8], [2.42, 10]] };
  const HOLD = 2.55, PASTE = .21, SHOW = 3.4, LEAD = 1.1;
  let take = null, held = false, rang = false, burst = { x: 0, y: 0, k: 1 };
  // A take is one hold of the key: release stays null while a person is still holding it.
  const begin = (press, release) => { take = { press, release, text: null, V: makeVoice(press, release ?? press + 30, D.updates) }; };
  function size() {
    const s = narrow() ? 1.08 : 1.45;
    bar.style.setProperty("--s", s);
    bar.maxW = Math.min(560, (root.clientWidth - 12) / s);
    burst = { x: root.clientWidth / 2, y: card.offsetTop + card.offsetHeight / 2, k: Math.min(1, root.clientWidth / 700) };
  }
  function frame(_, t) {
    if (!take) begin(t + LEAD, t + LEAD + HOLD);
    const k = take, rel = k.release ?? Infinity, paste = rel + PASTE;
    if (k.text == null && t >= rel) {
      const w = wordsAt(D.preview, D.updates, rel - k.press).words;
      k.text = !w ? "" : w === D.preview ? D.final : w + ".";
    }
    if (!held && t >= (k.text === "" ? rel + .4 : paste + SHOW + .45)) { begin(t + LEAD, t + LEAD + HOLD); return frame(_, t); }
    key.classList.toggle("down", t >= k.press && t < rel);
    // While the key is held there is no release yet, so nothing closes or fades.
    const text = k.text ?? "", shown = !!text && t >= paste, gone = k.text ? seg(t, paste + SHOW, paste + SHOW + .35) : 0;
    const open = out3(seg(t, k.press - .05, k.press + .2)), close = k.text == null ? 0 : k.text === "" ? seg(t, rel, rel + .3) : seg(t, paste, paste + .12);
    bar.style.opacity = (open * (1 - close)).toFixed(3);
    bar.style.transform = `scale(${lerp(.92, 1, open)})`;
    if (open * (1 - close) > 0) {
      const spin = t >= rel ? 1 - Math.exp(-(t - rel) / .12) : 0;
      setBar(bar, { ...wordsAt(D.preview, D.updates, t - k.press), env: d => k.V.env(t, d), spin, t, glow: d => k.V.glow(t, d), light: k.V.light(t) });
      bar.querySelector(".words").style.opacity = 1 - .5 * spin;
    }
    const txt = shown ? text : "";
    if (typed.textContent !== txt) typed.textContent = txt;
    typed.style.opacity = 1 - gone;
    const fl = (shown ? Math.exp(-(t - paste) * 3.2) : 0) * .35;
    typed.style.background = `rgba(62,106,225,${fl.toFixed(3)})`;
    typed.style.boxShadow = `0 0 0 5px rgba(62,106,225,${fl.toFixed(3)})`;
    caret.style.opacity = shown && gone === 0 ? 1 : Math.floor(t * 2.2) % 2 ? 0 : 1;
    card.style.transform = shown ? `scale(${1 + .018 * Math.exp(-(t - paste) * 8)})` : "";
    took.dataset.base = "translate(-50%, -50%)";
    if (shown) { pop(took, t, paste + .12, .4, .8, 14); took.style.opacity *= 1 - gone; } else took.style.opacity = 0;
    partsAt(parts, t, text ? paste : -99, burst.x, burst.y, 1.7, .55, burst.k);
    const lit = shown && gone < .5;
    h1.classList.toggle("typed", lit); h1.classList.toggle("listen", !lit);
    if (shown && !rang) { rang = true; ring(card, paste); }
  }
  const isKey = e => e.key === " " || e.key === "Enter";
  function press(e) {
    if (e.type === "keydown" ? e.repeat || !isKey(e) : e.button > 0) return;
    e.preventDefault();
    if (held || reduced) return;
    held = true;
    if (e.pointerId != null) key.setPointerCapture(e.pointerId);
    begin(now(), null);
  }
  function release(e) {
    if (!held || (e.type === "keyup" && !isKey(e))) return;
    held = false;
    const t = now();
    take.release = t; take.V = makeVoice(take.press, t, D.updates);
  }
  key.addEventListener("pointerdown", press);
  key.addEventListener("keydown", press);
  for (const ev of ["pointerup", "pointercancel", "lostpointercapture", "keyup", "blur"]) key.addEventListener(ev, release);
  key.addEventListener("contextmenu", e => e.preventDefault());
  function still() {
    typed.textContent = D.final; bar.style.opacity = 0;
    took.style.opacity = 1; took.style.transform = "translate(-50%, -50%)";
  }
  return { root, size, frame, still, reset() { if (!held) take = null; } };
})();

// ---------- speed: a cursor drags the Lip Service pill onto the board, then the bars race at 1/4 speed and stop at their medians ----------
const speed = (() => {
  const card = $("#bench"), after = $("#speed .after");
  const rows = $$(".r", card).map(r => ({ me: r.classList.contains("me"), s: +r.dataset.s, n: $(".n", r), b: $(".b", r), v: $(".v", r) }));
  const pill = rows[0].n, cur = $(".kc", pill);
  cur.innerHTML = arrow(COLORS[0]);
  const RATE = 4, GO = .6, DROP = .55, SLOWEST = Math.max(...rows.map(r => r.s));
  let g = { name: 0, px: 0, f: 1, gap: 14 };
  function size() {
    const cs = getComputedStyle(card), name = parseFloat(cs.getPropertyValue("--name")), val = parseFloat(cs.getPropertyValue("--val"));
    g = { name, px: ($(".rows", card).clientWidth - name - val) / SLOWEST, f: card.clientWidth / 1640, gap: narrow() ? 8 : 14 };
  }
  function frame(t) {
    const u = inOut(seg(t, .05, DROP)), lift = t < DROP ? 1 : 1 - outBack(seg(t, DROP, DROP + .3)), l = clamp(lift);
    pill.style.opacity = seg(t, 0, .12);
    pill.style.transform = `translate(${quad(u, 1450 * g.f, 760 * g.f, 0)}px, ${quad(u, 640 * g.f, -40 * g.f, 0)}px) translateY(-50%) scale(${1 + .07 * lift}) rotate(${-4 * lift}deg)`;
    pill.style.boxShadow = `0 ${10 + 12 * l}px ${24 + 22 * l}px rgba(0,0,0,${.4 + .2 * l})`;
    const away = seg(t, DROP + .2, DROP + .7);
    cur.style.opacity = 1 - away;
    cur.style.transform = `translate(${away * 40}px, ${away * 34}px)`;
    for (const { me, s, b, v } of rows) {
      const run = Math.max(0, Math.min(s, (t - GO) / RATE)), w = run * g.px, done = GO + s * RATE, lit = t >= done ? Math.exp(-(t - done) * 4) : 0;
      b.style.width = w + "px";
      b.style.opacity = t >= GO ? 1 : 0;
      v.style.left = g.name + w + g.gap + "px";
      v.textContent = run.toFixed(2) + " s";
      v.style.opacity = t >= GO ? (t >= done ? 1 : .35) : 0;
      v.style.transform = `translateY(-50%) scale(${1 + .12 * lit})`;
      if (me) b.style.boxShadow = `0 0 ${30 * lit}px rgba(90,139,255,${(.8 * lit).toFixed(3)})`;
    }
  }
  return { card, after, size, frame };
})();

// ---------- any app: three rows of icons sliding in alternating directions (CSS runs the slide) ----------
(() => {
  const ICONS = ["messages", "mail", "notes", "safari", "chatgpt", "claude", "visual-studio-code", "ghostty", "google-chrome", "obsidian", "pages", "textedit", "reminders", "terminal", "keynote", "freeform", "journal", "calendar", "numbers", "stickies", "shortcuts", "contacts", "maps"];
  const PINNED = [[0, 6, "cursor"], [1, 9, "t3-code-nightly"], [2, 4, "grok-bot"]];
  const host = $("#apps .rows");
  [0, 1, 2].forEach(r => {
    const row = document.createElement("div");
    row.className = "row";
    row.style.animationDelay = `${-[4, 21, 38][r]}s`;
    const set = Array.from({ length: 22 }, (_, i) => PINNED.find(([pr, pi]) => pr === r && pi === i)?.[2] ?? ICONS[(i * [7, 5, 3][r] + [0, 4, 9][r]) % ICONS.length]);
    [...set, ...set].forEach((name, i) => {
      const img = new Image(144, 144);
      img.src = `assets/apps/${name}.webp`; img.alt = ""; img.decoding = "async"; img.loading = "lazy";
      img.style.setProperty("--d", `${(.08 + rnd(i * 3.7 + r * 11) * .5).toFixed(3)}s`);
      row.append(img);
    });
    host.append(row);
  });
})();

// ---------- agents: Ghostwrite and Hand off take turns on one stage, as scenes 15 to 17 of the video ----------
const agents = (() => {
  const root = $("#stage"), tabs = $$(".mode");
  const mail = $(".mail", root), mTyped = $(".typed", mail), mCaret = $(".caret", mail);
  const meB = $(".bub.me", root), del = $(".meta", root), dots = $(".bub.dots", root), re = $(".bub.re", root);
  const keys = { ghost: $(".keys.ghost", root), hand: $(".keys.hand", root) }, cards = { ghost: $(".agcard.ghost", root), hand: $(".agcard.hand", root) };
  const ct = $(".ct", cards.hand), cb = $(".cb i", cards.hand), gBtns = $$(".btn", cards.ghost);
  const bar = makeBar({ agent: "Hermes", res: barRes() }); $(".barslot", root).append(bar);
  const GW = { press: .7, release: 2.2, text: "Tell her Thursday works, after 3", updates: [[.3, 1], [.5, 2], [.75, 3], [.95, 4], [1.15, 5], [1.3, 6]], draft: "Thursday works. Anytime after 3 is good." };
  GW.first = GW.release + .95; GW.ready = GW.first + .8; GW.ret = GW.ready + .4; GW.typed = GW.ret + .1; GW.length = GW.typed + 3;
  GW.steps = [[GW.release + .12, "Hermes is writing…", 1], [GW.first, "Writing", 1], [GW.ready, "Ready", 0]];
  const HO = { press: .7, release: 1.8, text: "Book a table for four Friday at 7", updates: [[.22, 2], [.42, 3], [.6, 5], [.8, 6], [.95, 7]] };
  HO.card = HO.release + .15; HO.sent = HO.card + 2; HO.reply = HO.sent + 1.05; HO.length = HO.reply + 3;
  HO.steps = [[HO.release + .12, "Sending to Hermes…", 1]];
  GW.V = makeVoice(GW.press, GW.release, GW.updates, 40); HO.V = makeVoice(HO.press, HO.release, HO.updates, 60);
  const bd = $(".bd", cards.ghost);
  bd.textContent = "";
  GW.draft.split(" ").forEach((w, i) => { if (i) bd.append(" "); const s = document.createElement("span"); s.className = "w"; s.textContent = w; bd.append(s); });
  const words = [...bd.children];
  let mode = "ghost", start = null;

  function setMode(m, t) {
    mode = m; start = t; root.dataset.mode = m;
    tabs.forEach(b => b.setAttribute("aria-pressed", String(b.dataset.mode === m)));
    const other = m === "ghost" ? "hand" : "ghost";
    keys[other].style.opacity = 0; cards[other].style.opacity = 0;
    mail.style.transform = "";
  }
  function size() {
    const s = narrow() ? 1 : 1.3;
    bar.style.setProperty("--s", s);
    bar.maxW = Math.min(560, (root.clientWidth - 8) / s);
  }
  // The bar listens under the agent's name with the halo up; at the release it shows the agent's line, as Ghostwriter.bar does.
  function barAt(c, t, gone) {
    const open = out3(seg(t, c.press - .05, c.press + .2));
    bar.style.opacity = (open * (1 - gone)).toFixed(3);
    bar.style.transform = `scale(${lerp(.92, 1, open)})`;
    if (open <= 0 || gone >= 1) return;
    const glow = d => c.V.glow(t, d), light = c.V.light(t) * (1 - seg(t, c.release, c.release + .15));
    const i = c.steps.findLastIndex(([at]) => t >= at);
    if (i < 0) {
      const spin = t >= c.release ? 1 - Math.exp(-(t - c.release) / .12) : 0;
      setBar(bar, { ...wordsAt(c.text, c.updates, t - c.press), env: d => c.V.env(t, d), spin, t, glow, light });
      bar.querySelector(".words").style.opacity = 1 - .5 * spin;
      return;
    }
    const [at, status, busy] = c.steps[i], before = i ? { status: c.steps[i - 1][1] } : { words: c.text };
    setBar(bar, { status, still: !busy, t, fromW: contentWidth(bar, before), grow: out3(seg(t, at, at + .25)), glow, light });
  }
  function keysAt(el, t, c) {
    const p = out3(seg(t, c.press - .25, c.press - .05)), gone = seg(t, c.release + .05, c.release + .3);
    el.style.opacity = p * (1 - gone);
    el.style.transform = `translateY(calc(-50% + ${(1 - p) * 20 + gone * 26}px)) scale(${lerp(.9, 1, p) - .06 * gone})`;
    el.style.filter = gone > 0 ? `blur(${gone * 8}px)` : "none";
    for (const k of el.querySelectorAll(".key")) k.classList.toggle("down", t >= c.press && t < c.release);
  }
  // Ghostwrite: say what you want, the agent drafts it, Return types it into the reply.
  function ghostAt(t) {
    keysAt(keys.ghost, t, GW);
    const gone = seg(t, GW.typed - .08, GW.typed + .06), shown = t >= GW.typed;
    barAt(GW, t, gone);
    const txt = shown ? GW.draft : "";
    if (mTyped.textContent !== txt) mTyped.textContent = txt;
    const fl = (shown ? Math.exp(-(t - GW.typed) * 3.2) : 0) * .35;
    mTyped.style.background = `rgba(62,106,225,${fl.toFixed(3)})`;
    mTyped.style.boxShadow = `0 0 0 5px rgba(62,106,225,${fl.toFixed(3)})`;
    mCaret.style.opacity = shown || Math.floor(t * 2.2) % 2 ? 1 : 0;
    mail.style.transform = shown ? `scale(${1 + .015 * Math.exp(-(t - GW.typed) * 8)})` : "";
    const card = cards.ghost;
    pop(card, t, GW.release + .2, .4, .94, 30);
    card.style.opacity *= 1 - gone;
    const step = (GW.ready - .1 - GW.first) / words.length;
    words.forEach((s, i) => { const p = out3(seg(t, GW.first + i * step, GW.first + i * step + .25)); s.style.opacity = p; s.style.filter = p < 1 ? `blur(${(1 - p) * 8}px)` : "none"; });
    gBtns.forEach((b, i) => pop(b, t, GW.ready + i * .06, .3, .85, 8));
    const hit = t >= GW.ret && t < GW.ret + .14;
    gBtns[0].style.transform += ` scale(${hit ? .95 : 1})`;
    gBtns[0].style.boxShadow = hit ? "0 0 30px rgba(90,139,255,.8)" : "none";
  }
  // Hand off: say a task, a shortened countdown (the app waits 5 s), then it lands in the agent's own app.
  function handAt(t) {
    keysAt(keys.hand, t, HO);
    const gone = seg(t, HO.sent - .05, HO.sent + .15);
    barAt(HO, t, gone);
    const card = cards.hand;
    pop(card, t, HO.card, .4, .94, 30);
    card.style.opacity *= 1 - gone;
    const left = clamp((HO.sent - t) / 2) * 2, msg = "Sending to Hermes in iMessage";
    if (ct.textContent !== msg) ct.textContent = msg;
    cb.style.width = 50 * left + "%";
    const p = outBack(seg(t, HO.sent, HO.sent + .35));
    meB.style.opacity = seg(t, HO.sent, HO.sent + .1);
    meB.style.transform = `translateX(${(1 - out3(seg(t, HO.sent, HO.sent + .3))) * -120}px) scale(${lerp(.6, 1, p)})`;
    del.style.opacity = out3(seg(t, HO.sent + .35, HO.sent + .6));
    dots.style.opacity = out3(seg(t, HO.sent + .5, HO.sent + .65)) * (1 - seg(t, HO.reply - .05, HO.reply + .05));
    [...dots.children].forEach((d, i) => { d.style.opacity = .45 + .55 * Math.max(0, Math.sin((t - i * .14) * 9)); });
    pop(re, t, HO.reply, .35, .7, 10);
  }
  const AT = { ghost: [ghostAt, GW], hand: [handAt, HO] };
  function frame(_, t) {
    if (start == null) setMode("ghost", t);
    if (t - start > AT[mode][1].length) setMode(mode === "ghost" ? "hand" : "ghost", t);
    AT[mode][0](t - start);
  }
  function still() { mode === "ghost" ? ghostAt(GW.ready + .38) : handAt(HO.reply + 1); }
  tabs.forEach(b => b.addEventListener("click", () => { setMode(b.dataset.mode, now()); if (reduced) still(); }));
  return { root, size, frame, still };
})();

// ---------- privacy: the laptop's waveform keeps moving; the X and the dimmed cloud are CSS ----------
const privacy = (() => {
  const rects = $$("#pic .lw rect"), ENV = [.35, .55, .8, .95, 1, .95, .8, .55, .35];
  let last = -1;
  function frame(_, t) {
    const tick = Math.floor(t * 12);
    if (tick === last) return;
    last = tick;
    rects.forEach((r, i) => { const h = 14 + ENV[i] * (30 + 90 * Math.pow(rnd(tick * 9 + i), 1.6)); r.setAttribute("height", h.toFixed(1)); r.setAttribute("y", (123 - h / 2).toFixed(1)); });
  }
  return { root: $("#pic"), frame };
})();

// ---------- end card: "Free and local." lands with a burst and a ring through the field, as the drop does in the video ----------
const end = (() => {
  const root = $("#end"), cap = $(".cap", root), parts = makeParts($(".particles", root), 56, 47), BURST = .55;
  function frame(t) {
    partsAt(parts, t, BURST, root.clientWidth / 2, cap.offsetTop + cap.offsetHeight / 2, 1.7, .6, Math.min(1, root.clientWidth / 900));
  }
  return { root, frame, start: t => ring(cap, t + BURST) };
})();

// ---------- scenes: each starts when it first comes on screen and only draws while it is on screen ----------
const SCENES = [
  { el: hero.root, frame: hero.frame, trigger: $("#hero") },
  { el: speed.card, frame: speed.frame, once: 4.4, onStart: () => speed.after.classList.add("in") },
  { el: agents.root, frame: agents.frame },
  { el: privacy.root, frame: privacy.frame },
  { el: end.root, frame: end.frame, once: 2, onStart: end.start },
].map(s => ({ ...s, start: null, visible: false, done: false, ran: false }));

function sizeAll() { field.resize(); hero.size(); speed.size(); agents.size(); }

function startStill() {
  sizeAll();
  $$("[data-reveal], .cap").forEach(el => el.classList.add("in"));
  speed.after.classList.add("in");
  field.draw({ y: 0, lz: CAM.lz0 }, CAM.lz0, .85, []);
  hero.still(); speed.frame(99); agents.still();
  addEventListener("resize", () => { sizeAll(); field.draw({ y: 0, lz: CAM.lz0 }, CAM.lz0, .85, []); speed.frame(99); });
}

function startMotion() {
  sizeAll();
  speed.frame(0);
  const reveal = new IntersectionObserver(es => {
    const t = now();
    for (const e of es) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("in");
      reveal.unobserve(e.target);
      for (const s of SCENES) if ((s.trigger ?? s.el) === e.target && s.start == null) { s.start = t; s.onStart?.(t); }
    }
  }, { rootMargin: "0px 0px -8% 0px", threshold: .2 });
  $$("[data-reveal]").forEach(el => reveal.observe(el));
  $$(".cap").filter(c => !c.closest(".after")).forEach(el => reveal.observe(el));
  const seen = new IntersectionObserver(es => {
    for (const e of es) {
      for (const s of SCENES) if (s.el === e.target) s.visible = e.isIntersecting;
      e.target.classList.toggle("live", e.isIntersecting);
    }
  }, { rootMargin: "120px 0px" });
  SCENES.forEach(s => seen.observe(s.el));
  seen.observe($("#apps"));

  let raf = 0, last = now();
  function tick(ms) {
    raf = requestAnimationFrame(tick);
    const t = ms / 1000, dt = Math.min(.1, Math.max(0, t - last));
    last = t;
    drawField(t, dt);
    for (const s of SCENES) {
      if (s.start == null || !s.visible || s.done) continue;
      let lt = t - s.start;
      if (s.once != null && lt >= s.once) { lt = s.once; s.done = true; }
      s.frame(lt, t);
    }
  }
  raf = requestAnimationFrame(tick);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { cancelAnimationFrame(raf); raf = 0; return; }
    hero.reset(); last = now(); cam.drawn = -1;
    if (!raf) raf = requestAnimationFrame(tick);
  });
  let pending = 0;
  addEventListener("resize", () => { cancelAnimationFrame(pending); pending = requestAnimationFrame(() => { sizeAll(); cam.drawn = -1; }); });
}

// The bar measures words in its own font, so it waits for the fonts and drops its widths when a font arrives late.
document.fonts.addEventListener?.("loadingdone", () => { TEXT_W.clear(); hero.size(); agents.size(); });
await Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 700))]);
if (reduced) startStill(); else startMotion();
