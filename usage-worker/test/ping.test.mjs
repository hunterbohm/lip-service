import assert from "node:assert/strict";
import { test } from "node:test";
import worker, { parsePing } from "../src/index.js";

const now = new Date("2026-11-02T18:00:00Z");
const install = "a".repeat(64);
const good = { install, version: "1.0.6", macos: "26.0.1", day: "2026-11-02", used: ["dictation"] };
const parse = (body) => parsePing(typeof body === "string" ? body : JSON.stringify(body), now);

test("accepts a well-formed report", () => {
  assert.deepEqual(parse(good), good);
  assert.ok(parse({ ...good, used: ["dictation", "ghostwrite", "handoff"] }));
});

test("ignores malformed reports", () => {
  const bad = [
    "not json",
    "[]",
    "null",
    { ...good, install: "short" },
    { ...good, install: "A".repeat(64) },
    { ...good, version: "" },
    { ...good, version: "1.0 beta" },
    { ...good, macos: "x".repeat(40) },
    { ...good, day: "2026-13-40" },
    { ...good, day: "2026-11-05" },
    { ...good, day: "2026-10-30" },
    { ...good, used: [] },
    { ...good, used: ["dictation", "dictation"] },
    { ...good, used: ["dictation", "agent:hermes"] },
    { ...good, used: "dictation" },
    { ...good, extra: "text" },
    { install, version: "1.0.6", macos: "26.0.1", day: "2026-11-02" },
    JSON.stringify(good) + " ".repeat(2000),
  ];
  for (const body of bad) assert.equal(parse(body), null, JSON.stringify(body).slice(0, 80));
});

test("accepts yesterday and tomorrow in UTC, so a clock a little off still counts", () => {
  assert.ok(parse({ ...good, day: "2026-11-01" }));
  assert.ok(parse({ ...good, day: "2026-11-03" }));
});

function fakeDb() {
  const rows = new Map();
  return {
    rows,
    prepare: (sql) => ({
      bind: (...values) => ({
        run: async () => {
          assert.match(sql, /INSERT OR IGNORE INTO pings/);
          const key = `${values[0]}|${values[1]}`;
          if (!rows.has(key)) rows.set(key, values);
        },
      }),
    }),
  };
}

const post = (body) => new Request("https://x.test/v1/ping", { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) });

test("stores one row per install and day", async () => {
  const DB = fakeDb();
  const today = new Date().toISOString().slice(0, 10);
  const report = { ...good, day: today };
  assert.equal((await worker.fetch(post(report), { DB })).status, 204);
  assert.equal((await worker.fetch(post({ ...report, used: ["handoff"] }), { DB })).status, 204);
  assert.equal(DB.rows.size, 1);
  assert.deepEqual([...DB.rows.values()][0], [install, today, "1.0.6", "26.0.1", 1, 0, 0]);
});

test("stores nothing for a malformed report", async () => {
  const DB = fakeDb();
  assert.equal((await worker.fetch(post("{}"), { DB })).status, 400);
  assert.equal(DB.rows.size, 0);
});

test("the read endpoint needs the token", async () => {
  const env = { DB: fakeDb(), READ_TOKEN: "secret-token" };
  const read = (headers) => worker.fetch(new Request("https://x.test/v1/stats", { headers }), env);
  assert.equal((await read({})).status, 401);
  assert.equal((await read({ authorization: "Bearer wrong" })).status, 401);
  assert.equal((await worker.fetch(new Request("https://x.test/v1/stats"), { DB: env.DB })).status, 401);
  assert.equal((await worker.fetch(new Request("https://x.test/nope"), { DB: env.DB })).status, 404);
});
