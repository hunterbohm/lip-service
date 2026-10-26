#!/usr/bin/env python3
"""Score `Dictation --bench` output against the bakeoff: WER and vocabulary hits on the synthetic clips, and
release-to-text latency. Reuses score.py's normalization, WER and vocabulary-hit functions.

usage: e2e_score.py RESULTS.jsonl
Exits 1 when a dictation errored, vocabulary hits fall below 18 of 20, or WER on the synthetic clips rises
above 3.2%.
"""
import json, os, re, sys

BENCH = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH)
from score import TELLA, VOCAB, edits, norm_words, pct, vocab_hits  # noqa: E402

MIN_VOCAB_HITS = 18
MAX_WER = 3.2
BAKEOFF = [
    "bakeoff Parakeet v2, boosting at 0.7, 1 round, no idle hold:  p50 0.232 s  p95 0.420 s  WER 1.3%  vocabulary 18/20",
    "bakeoff Parakeet v2, boosting default, 5 rounds, idle hold:   p50 0.288 s  p95 0.499 s  WER 3.2%  vocabulary 18/20",
    "bakeoff Parakeet v2, no boosting, 5 rounds, idle hold:        p50 0.160 s  p95 0.293 s  WER 4.3%  vocabulary 12/20",
]


def main(path):
    refs = {r["id"]: r["text"] for r in map(json.loads, open(os.path.join(BENCH, "manifest.jsonl")))}
    rows, junk = [], 0
    for line in open(path):
        if line.startswith("{"):
            rows.append(json.loads(line))
        elif line.strip():
            junk += 1
    scored = [r for r in rows if r["round"] > 0]
    ok = [r for r in scored if "error" not in r]
    errors = len(scored) - len(ok)
    rounds = sorted({r["round"] for r in scored})
    if not ok:
        print(f"FAIL: no successful dictations in {path}")
        return 1

    e = n = hits = total = 0
    real_e = real_n = 0
    missed = []
    for r in ok:
        if r["clip"] in refs:
            ref = norm_words(refs[r["clip"]])
            e += edits(ref, norm_words(r["text"]))
            n += len(ref)
            h, t = vocab_hits(refs[r["clip"]], r["text"])
            hits += h
            total += t
            if r["round"] == rounds[0]:
                missed += [f"{term}({r['clip']})" for term in VOCAB
                           if re.search(r"\b%s\b" % term, refs[r["clip"]]) and not re.search(r"\b%s\b" % term, r["text"], flags=re.I)]
        elif r["clip"] in TELLA:
            ref = norm_words(TELLA[r["clip"]])
            real_e += edits(ref, norm_words(r["text"]))
            real_n += len(ref)
    wer = 100 * e / n if n else float("nan")
    per_round = len(rounds) or 1
    vocab = hits / per_round
    vocab_total = total / per_round

    latency = sorted(r["release_to_text_s"] for r in ok)
    stage = lambda key: pct([r[key] for r in ok], .5)  # noqa: E731
    print(f"rows {len(scored)} scored over {len(rounds)} rounds, {errors} errors, {junk} non-JSON lines")
    print(f"WER on synthetic clips: {wer:.1f}% (gate {MAX_WER}%)")
    print(f"vocabulary hits: {vocab:.1f}/{vocab_total:.0f} (gate {MIN_VOCAB_HITS}); missed in round {rounds[0]}: {', '.join(missed) or 'none'}")
    if real_n:
        print(f"WER on real clips against Tella's transcript: {100 * real_e / real_n:.1f}% (not ground truth)")
    print(f"release to text: p50 {pct(latency, .5):.3f} s  p95 {pct(latency, .95):.3f} s  max {latency[-1]:.3f} s  (n={len(latency)})")
    print(f"stage p50: waited {stage('waited_s'):.3f} s  decode {stage('decode_s'):.3f} s  rescore {stage('rescore_s'):.3f} s  finish {stage('finish_s') * 1e6:.0f} us")
    for line in BAKEOFF:
        print(line)

    failures = []
    if errors:
        failures.append(f"{errors} dictations errored")
    if vocab < MIN_VOCAB_HITS:
        failures.append(f"vocabulary hits {vocab:.1f} below {MIN_VOCAB_HITS}")
    if wer > MAX_WER:
        failures.append(f"WER {wer:.1f}% above {MAX_WER}%")
    if failures:
        print("FAIL: " + "; ".join(failures))
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
