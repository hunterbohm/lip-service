const USES = ["dictation", "ghostwrite", "handoff"];
const HEX64 = /^[0-9a-f]{64}$/;
const VERSION = /^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const KEYS = ["day", "install", "macos", "used", "version"];
const MAX_BODY = 1024;
const DAY_MS = 86_400_000;

export function utcDay(date) {
  return date.toISOString().slice(0, 10);
}

/** The report in the body, or null when anything about it is off. Unknown keys reject the whole report. */
export function parsePing(text, now = new Date()) {
  if (text.length > MAX_BODY) return null;
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return null;
  }
  if (body === null || typeof body !== "object" || Array.isArray(body)) return null;
  if (Object.keys(body).sort().join() !== KEYS.join()) return null;
  const { install, version, macos, day, used } = body;
  if (typeof install !== "string" || !HEX64.test(install)) return null;
  if (typeof version !== "string" || !VERSION.test(version)) return null;
  if (typeof macos !== "string" || !VERSION.test(macos)) return null;
  if (typeof day !== "string" || !DAY.test(day)) return null;
  const parsed = new Date(`${day}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime()) || utcDay(parsed) !== day) return null;
  if (Math.abs(parsed.getTime() - Date.parse(`${utcDay(now)}T00:00:00Z`)) > DAY_MS) return null;
  if (!Array.isArray(used) || used.length < 1 || used.length > USES.length) return null;
  if (new Set(used).size !== used.length || !used.every((use) => USES.includes(use))) return null;
  return { install, version, macos, day, used };
}

async function sameToken(given, expected) {
  if (!expected) return false;
  const digest = async (value) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  const [a, b] = await Promise.all([digest(given), digest(expected)]);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

async function stats(db, now) {
  const from = (days) => utcDay(new Date(now.getTime() - (days - 1) * DAY_MS));
  const today = utcDay(now);
  const one = async (sql, ...binds) => (await db.prepare(sql).bind(...binds).first()) ?? {};
  const all = async (sql, ...binds) => (await db.prepare(sql).bind(...binds).all()).results ?? [];
  const [daily, week, month, total, versions] = await Promise.all([
    all(
      `SELECT day, COUNT(*) AS installs, SUM(dictation) AS dictation, SUM(ghostwrite) AS ghostwrite, SUM(handoff) AS handoff
       FROM pings WHERE day >= ? GROUP BY day ORDER BY day`,
      from(30),
    ),
    one("SELECT COUNT(DISTINCT install) AS installs FROM pings WHERE day >= ?", from(7)),
    one("SELECT COUNT(DISTINCT install) AS installs FROM pings WHERE day >= ?", from(30)),
    one("SELECT COUNT(DISTINCT install) AS installs FROM pings"),
    all(
      "SELECT version, COUNT(DISTINCT install) AS installs FROM pings WHERE day >= ? GROUP BY version ORDER BY installs DESC",
      from(7),
    ),
  ]);
  const byDay = Object.fromEntries(daily.map((row) => [row.day, row]));
  return {
    asOf: now.toISOString(),
    today: { day: today, activeInstalls: byDay[today]?.installs ?? 0 },
    last7Days: { activeInstalls: week.installs ?? 0, byVersion: Object.fromEntries(versions.map((row) => [row.version, row.installs])) },
    last30Days: { activeInstalls: month.installs ?? 0 },
    allTime: { installs: total.installs ?? 0 },
    daily,
  };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const now = new Date();
    if (url.pathname === "/v1/ping" && request.method === "POST") {
      const ping = parsePing(await request.text(), now);
      if (!ping) return new Response(null, { status: 400 });
      const flag = (use) => (ping.used.includes(use) ? 1 : 0);
      await env.DB.prepare(
        "INSERT OR IGNORE INTO pings (install, day, version, macos, dictation, ghostwrite, handoff) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
        .bind(ping.install, ping.day, ping.version, ping.macos, flag("dictation"), flag("ghostwrite"), flag("handoff"))
        .run();
      return new Response(null, { status: 204 });
    }
    if (url.pathname === "/v1/stats" && request.method === "GET") {
      const given = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "");
      if (!(await sameToken(given, env.READ_TOKEN))) return new Response("unauthorized", { status: 401 });
      return Response.json(await stats(env.DB, now), { headers: { "cache-control": "no-store" } });
    }
    return new Response("not found", { status: 404 });
  },
};
