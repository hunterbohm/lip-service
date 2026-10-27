#!/usr/bin/env python3
"""Score RivalBench results: per app, word error rate and name hits on the synthetic clips, and release-to-text time.

usage: rivals_score.py RESULTS.jsonl [--json OUT.json]
Round 0 is warm-up and is not scored. Reuses score.py's normalization, WER and vocabulary-hit functions.
"""
import argparse, json, os, re, statistics, sys
from collections import defaultdict

BENCH = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH)
from score import VOCAB, edits, norm_words, pct, vocab_hits  # noqa: E402


def summarize(rows, refs):
    by_app = defaultdict(list)
    for r in rows:
        if r["round"] > 0:
            by_app[r["app"]].append(r)
    out = {}
    for app, trials in by_app.items():
        ok = [r for r in trials if not r.get("error")]
        rounds = sorted({r["round"] for r in trials})
        e = n = hits = total = 0
        missed = defaultdict(int)
        for r in ok:
            ref = refs[r["clip"]]
            words = norm_words(ref)
            e += edits(words, norm_words(r["text"]))
            n += len(words)
            h, t = vocab_hits(ref, r["text"])
            hits += h
            total += t
            for term in VOCAB:
                if re.search(r"\b%s\b" % term, ref) and not re.search(r"\b%s\b" % term, r["text"], flags=re.I):
                    missed[term] += 1
        latency = sorted(r["release_to_final_s"] for r in ok)
        round_p50 = [statistics.median(r["release_to_final_s"] for r in ok if r["round"] == k) for k in rounds
                     if any(r["round"] == k for r in ok)]
        out[app] = {
            "trials": len(trials),
            "errors": len(trials) - len(ok),
            "error_kinds": sorted({r["error"] for r in trials if r.get("error")}),
            "rounds": len(rounds),
            "wer_pct": 100 * e / n if n else None,
            "names_per_round": hits / len(rounds) if rounds else None,
            "names_possible": total / len(rounds) if rounds else None,
            "missed_names": dict(missed),
            "p50_s": pct(latency, .5),
            "p95_s": pct(latency, .95),
            "max_s": latency[-1] if latency else None,
            "round_p50_range_s": [min(round_p50), max(round_p50)] if round_p50 else None,
            "first_to_final_max_s": max((r["release_to_final_s"] - r["release_to_first_s"]) for r in ok) if ok else None,
        }
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("results")
    ap.add_argument("--json")
    args = ap.parse_args()
    refs = {r["id"]: r["text"] for r in map(json.loads, open(os.path.join(BENCH, "manifest.jsonl")))}
    rows = [json.loads(line) for line in open(args.results) if line.startswith("{")]
    summary = summarize(rows, refs)
    print(f"{'app':14} {'trials':>6} {'err':>4} {'WER':>6} {'names':>9} {'p50 s':>6} {'p95 s':>6} {'max s':>6}  round p50 range")
    for app, s in sorted(summary.items(), key=lambda kv: kv[1]["p50_s"]):
        names = f"{s['names_per_round']:.1f}/{s['names_possible']:.0f}"
        rng = "-" if not s["round_p50_range_s"] else f"{s['round_p50_range_s'][0]:.3f} to {s['round_p50_range_s'][1]:.3f} s"
        print(f"{app:14} {s['trials']:>6} {s['errors']:>4} {s['wer_pct']:>5.1f}% {names:>9} {s['p50_s']:>6.3f} {s['p95_s']:>6.3f} "
              f"{s['max_s']:>6.3f}  {rng}")
        if s["errors"]:
            print(f"{'':14} errors: {', '.join(s['error_kinds'])}")
        if s["missed_names"]:
            print(f"{'':14} missed: {', '.join(f'{k} x{v}' for k, v in sorted(s['missed_names'].items()))}")
    if args.json:
        json.dump(summary, open(args.json, "w"), indent=2)


if __name__ == "__main__":
    main()
