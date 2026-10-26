#!/usr/bin/env python3
"""Score dictbench results: release-to-final latency per engine, WER and vocabulary hits on the synthetic clips."""
import json, math, os, re, sys
from collections import defaultdict

VOCAB = ["Hermes", "ProfitPilot", "Nective", "HubSpot", "Beehiiv", "Obsidian", "TaskNotes",
         "Tailscale", "Claude", "Codex", "Granola", "Infisical", "Executor"]
FILLERS = {"um", "uh", "erm", "er", "ah", "hmm", "mm"}
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
# Real clips, cut from a recording of the author: boundaries, the recording tool's transcript (not ground truth)
# and the source, in bench/real.json, which stays out of the repo. Without it the real clips are skipped.
REAL_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "real.json")
REAL = json.load(open(REAL_FILE)) if os.path.exists(REAL_FILE) else {"source": None, "clips": []}
TELLA = {clip["id"]: clip["transcript"] for clip in REAL["clips"]}


def num_words(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + num_words(n % 100))
    return num_words(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + num_words(n % 1000))


def norm_words(text):
    t = text.lower().replace("%", " percent").replace("-", " ")
    t = re.sub(r"\d+", lambda m: " " + num_words(int(m.group())) + " ", t)
    t = re.sub(r"[^a-z' ]+", " ", t)
    return [w.strip("'") for w in t.split() if w.strip("'") and w.strip("'") not in FILLERS]


def edits(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[-1]


def vocab_hits(ref, hyp):
    total = hits = 0
    for term in VOCAB:
        n = len(re.findall(r"\b%s\b" % term, ref))
        if n:
            total += n
            hits += min(n, len(re.findall(r"\b%s\b" % term, hyp, flags=re.I)))
    return hits, total


def pct(vals, p):
    s = sorted(vals)
    return s[max(0, math.ceil(p * len(s)) - 1)] if s else float("nan")


def load(paths):
    rows, junk = [], 0
    for p in paths:
        for line in open(p):
            if line.startswith("{"):
                rows.append(json.loads(line))
            elif line.strip():
                junk += 1
    return rows, junk


def main(paths):
    refs = {r["id"]: r["text"] for r in map(json.loads, open("manifest.jsonl"))}
    rows, junk = load(paths)
    by = defaultdict(list)
    for r in rows:
        if r["round"] > 0:
            by[r["engine"]].append(r)
    print(f"rows={len(rows)} non-json stdout lines={junk}")
    hdr = f"{'engine':10} {'n':>4} {'err':>3} {'p50 s':>6} {'p95 s':>6} {'max s':>6} | {'syn p50':>7} {'real p50':>8} | {'WER syn':>7} {'WER range':>11} | {'vocab':>7} | {'vs Tella':>8}"
    print(hdr)
    print("-" * len(hdr))
    order = ["sa", "sa-vocab", "dt", "dt-vocab", "pk", "pk-vocab", "pk-vocab-strict", "wh"]
    engines = sorted(by, key=lambda e: order.index(e) if e in order else 99)
    for eng in engines:
        rs = by[eng]
        ok = [r for r in rs if "error" not in r]
        lat = [r["release_to_final_s"] for r in ok]
        syn = [r["release_to_final_s"] for r in ok if r["clip"] in refs]
        real = [r["release_to_final_s"] for r in ok if r["clip"] in TELLA]
        per_round = defaultdict(lambda: [0, 0])
        e_all = n_all = vh = vt = 0
        te = tn = 0
        for r in ok:
            if r["clip"] in refs:
                ref = norm_words(refs[r["clip"]])
                e = edits(ref, norm_words(r["text"]))
                e_all += e; n_all += len(ref)
                per_round[r["round"]][0] += e; per_round[r["round"]][1] += len(ref)
                h, t = vocab_hits(refs[r["clip"]], r["text"])
                vh += h; vt += t
            elif r["clip"] in TELLA:
                ref = norm_words(TELLA[r["clip"]])
                te += edits(ref, norm_words(r["text"])); tn += len(ref)
        full = sum(len(norm_words(t)) for t in refs.values())
        rounds = [e / n for e, n in per_round.values() if n == full] or [float("nan")]
        n_vocab = sum(vocab_hits(t, t)[1] for t in refs.values())
        print(f"{eng:10} {len(rs):4} {len(rs) - len(ok):3} {pct(lat, .5):6.3f} {pct(lat, .95):6.3f} {max(lat):6.3f} | "
              f"{pct(syn, .5):7.3f} {pct(real, .5) if real else float('nan'):8.3f} | "
              f"{100 * e_all / n_all:6.1f}% {100 * min(rounds):4.1f}-{100 * max(rounds):4.1f}% | "
              f"{n_vocab * vh / vt:4.1f}/{n_vocab:<2} | {100 * te / tn if tn else float('nan'):7.1f}%")
    print("\nrelease-to-final p50 by clip length, and spread of per-round p50s")
    print(f"{'engine':10} {'<6s':>6} {'6-10s':>6} {'>10s':>6} {'u12 18s':>8} | {'round p50 range':>15} | {'press-to-ready p50':>18}")
    for eng in engines:
        ok = [r for r in by[eng] if "error" not in r]
        b = lambda lo, hi: [r["release_to_final_s"] for r in ok if lo <= r["audio_s"] < hi]  # noqa: E731
        u12 = [r["release_to_final_s"] for r in ok if r["clip"] == "u12"]
        rp = [pct([r["release_to_final_s"] for r in ok if r["round"] == k], .5) for k in sorted({r["round"] for r in ok})]
        setup = [r["setup_s"] for r in ok if "setup_s" in r]
        print(f"{eng:10} {pct(b(0, 6), .5):6.3f} {pct(b(6, 10), .5):6.3f} {pct(b(10, 99), .5):6.3f} {pct(u12, .5):8.3f} | "
              f"{min(rp):6.3f}-{max(rp):6.3f}  | {pct(setup, .5) if setup else float('nan'):18.3f}")
    print("\nvocabulary terms missed (round 1)")
    for eng in engines:
        miss = []
        for r in by[eng]:
            if r["round"] == 1 and r["clip"] in refs and "error" not in r:
                for term in VOCAB:
                    if re.search(r"\b%s\b" % term, refs[r["clip"]]) and not re.search(r"\b%s\b" % term, r["text"], flags=re.I):
                        miss.append(f"{term}({r['clip']})")
        print(f"{eng:10} {', '.join(miss) or 'none'}")
    with open("results/texts-round1.txt", "w") as f:
        for clip in sorted({r["clip"] for r in rows}):
            f.write(f"== {clip}  REF: {refs.get(clip) or TELLA.get(clip)}\n")
            for r in rows:
                if r["clip"] == clip and r["round"] == 1:
                    f.write(f"  {r['engine']:9} {r.get('text', r.get('error'))}\n")
    errs = [r for r in rows if "error" in r]
    for r in errs[:10]:
        print("ERROR", r["engine"], r["clip"], r["round"], r["error"][:300])


if __name__ == "__main__":
    main(sys.argv[1:])
