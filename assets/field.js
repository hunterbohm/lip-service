// The launch video's background (launch.html drawBg): a halftone field sampled in world space, so it zooms and pans with
// the camera, plus dotted streaks that stretch with the camera's speed. Here the camera is driven by scroll, not a timeline.
const clamp = x => x < 0 ? 0 : x > 1 ? 1 : x;
const smooth = x => x * x * x * (x * (x * 6 - 15) + 10);

function hash(i, j) {
  let h = (Math.imul(i, 374761393) + Math.imul(j, 668265263)) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177); h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}
function vnoise(x, y) {
  const i = Math.floor(x), j = Math.floor(y), fx = x - i, fy = y - j, u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy);
  const a = hash(i, j), b = hash(i + 1, j), c = hash(i, j + 1), d = hash(i + 1, j + 1);
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
}
// Four octaves, each twice the size of the last: as the zoom grows the biggest fades out while a smaller one fades in,
// so the field looks the same at any zoom and the camera can fly forward forever.
function zoomLayers(z2, kScale) {
  const n0 = Math.floor(z2), f = z2 - n0, ls = [];
  for (let j = 0; j < 4; j++) ls.push({ n: n0 + j, w: Math.sin(Math.PI * (j + 1 - f) / 4) ** 2 });
  const ws = ls.reduce((a, l) => a + l.w, 0);
  for (const l of ls) { l.w /= ws; l.k = 2 ** l.n * 2.4 / 900 * kScale; l.ox = l.n * 17.31; l.oy = -l.n * 9.13; }
  return ls;
}

const BLUE = "78,128,255", HOT = "185,206,255";
const STYLES = [...Array(6)].map((_, q) => `rgba(${BLUE},${((q + 1) / 6 * .9).toFixed(3)})`)
  .concat([...Array(6)].map((_, q) => `rgba(${HOT},${((q + 1) / 6).toFixed(3)})`));

export function createField(canvas) {
  const ctx = canvas.getContext("2d", { alpha: false });
  let W = 0, H = 0, dpr = 1, step = 12, sz = 4, kScale = 1, n = 0;
  let cx, cy, vign, hot, buckets, counts, stars = [], span = 3;

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 3);
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    const small = W < 700;
    step = small ? 10 : 12; sz = small ? 3 : 4;
    kScale = 1920 / Math.max(1000, Math.min(1920, W));
    const cols = Math.ceil(W / step), rows = Math.ceil(H / step);
    n = cols * rows;
    cx = new Float32Array(n); cy = new Float32Array(n); vign = new Float32Array(n); hot = new Uint8Array(n);
    let k = 0;
    for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++, k++) {
      const x = step / 2 + i * step, y = step / 2 + j * step;
      const nx = (x - W / 2) / (W * .52), ny = (y - H * .48) / (H * .555);
      cx[k] = x; cy[k] = y;
      vign[k] = (.14 + .86 * clamp((Math.sqrt(nx * nx + ny * ny) - .42) / .75)) * (small ? .7 : 1);
      hot[k] = hash(i, j) > .93 ? 1 : 0;
    }
    buckets = STYLES.map(() => new Int32Array(n)); counts = new Int32Array(STYLES.length);
    span = Math.log(20);
    const count = Math.max(20, Math.min(90, Math.round(W * H / 26000)));
    stars = Array.from({ length: count }, (_, i) => {
      const q = m => { const x = Math.sin((i + 1) * 127.1 + m * 311.7) * 43758.5453; return x - Math.floor(x); };
      const a = q(1) * Math.PI * 2;
      return { c: Math.cos(a), s: Math.sin(a), p: q(2), d: .3 + .7 * q(3), hot: q(4) > .8 };
    });
  }

  // cam: { y, lz } (world pan, log zoom). prevLz: the zoom 60 ms ago, for the streaks. rings: [{ x, y, age }] in CSS px.
  function draw(cam, prevLz, L = 1, rings = []) {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = "#08090B"; ctx.fillRect(0, 0, W, H);
    const z = Math.exp(cam.lz), [l0, l1, l2, l3] = zoomLayers(cam.lz / Math.LN2, kScale);
    const ringSpeed = Math.max(1100, 2300 * W / 1920);
    counts.fill(0);
    for (let k = 0; k < n; k++) {
      const wx = (cx[k] - W / 2) / z, wy = cam.y + (cy[k] - H / 2) / z;
      const v = l0.w * vnoise(wx * l0.k + l0.ox, wy * l0.k + l0.oy) + l1.w * vnoise(wx * l1.k + l1.ox, wy * l1.k + l1.oy)
        + l2.w * vnoise(wx * l2.k + l2.ox, wy * l2.k + l2.oy) + l3.w * vnoise(wx * l3.k + l3.ox, wy * l3.k + l3.oy);
      let a = clamp(((.5 + (v - .5) * 1.75) - .44) * 3.8) * vign[k] * L;
      for (const g of rings) {
        const r = Math.hypot(cx[k] - g.x, cy[k] - g.y);
        a += clamp(1 - Math.abs(r - g.age * ringSpeed) / 150) * .9 * (1 - clamp(g.age / 1.1));
      }
      if (a < .05) continue;
      const q = Math.round(Math.min(a, 1) * 6);
      if (!q) continue;
      const b = hot[k] * 6 + q - 1;
      buckets[b][counts[b]++] = k;
    }
    const h = sz / 2;
    for (let b = 0; b < STYLES.length; b++) {
      const c = counts[b];
      if (!c) continue;
      const ids = buckets[b];
      ctx.beginPath();
      for (let m = 0; m < c; m++) { const k = ids[m]; ctx.rect(cx[k] - h, cy[k] - h, sz, sz); }
      ctx.fillStyle = STYLES[b]; ctx.fill();
    }
    drawStars(cam.lz, prevLz, L);
  }

  // Each star rides outward from the center as the camera zooms (u runs from 1/20 to 1 of the way out), and wraps back in once it leaves the frame.
  // It is drawn as a dotted trail from where it was 60 ms ago: a speck at rest, a line while the page scrolls.
  function drawStars(lz, prevLz, L) {
    const grid = sz, gap = step;
    for (const s of stars) {
      const sp = .7 + .3 * s.d, g = lz * sp + s.p * span, gp = prevLz * sp + s.p * span;
      const wrap = Math.floor(g / span), u = Math.exp(g - (wrap + 1) * span);
      const up = Math.floor(gp / span) === wrap ? Math.exp(gp - (wrap + 1) * span) : u;
      const x1 = W / 2 + s.c * u * W * .72, y1 = H / 2 + s.s * u * H * .72;
      const x0 = W / 2 + s.c * up * W * .72, y0 = H / 2 + s.s * up * H * .72;
      if (Math.max(x0, x1) < -20 || Math.min(x0, x1) > W + 20 || Math.max(y0, y1) < -20 || Math.min(y0, y1) > H + 20) continue;
      const len = Math.hypot(x1 - x0, y1 - y0), dots = Math.min(40, Math.floor(len / gap));
      const a = Math.min(1, (.35 + .65 * s.d) * (.35 + Math.min(len / 160, 1) * .65)) * Math.min(L, 1.1) * .9 * smooth(clamp((u - .12) / .4));
      if (a < .04) continue;
      const size = s.hot ? sz + 1 : sz, rgb = s.hot ? HOT : BLUE;
      for (let k = 0; k <= dots; k++) {
        const q = dots ? k / dots : 0;
        ctx.fillStyle = `rgba(${rgb},${(a * (1 - q * .85)).toFixed(3)})`;
        ctx.fillRect(Math.round((x1 + (x0 - x1) * q) / grid) * grid - size / 2, Math.round((y1 + (y0 - y1) * q) / grid) * grid - size / 2, size, size);
      }
    }
  }

  return { resize, draw };
}
