#!/usr/bin/env python3
"""Build 16 kHz mono WAV clips: synthetic dictation from manifest.jsonl via `say`, plus real clips cut from a recording of the author,
listed in bench/real.json, which stays out of the repo."""
import json, os, subprocess, sys, wave

from score import REAL

ROOT = os.path.dirname(os.path.abspath(__file__))
CLIPS = os.path.join(ROOT, "clips")
VOICE = os.environ.get("VOICE", "Samantha")


def duration(path):
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()


def synth(rows):
    for r in rows:
        out = os.path.join(CLIPS, r["id"] + ".wav")
        aiff = out + ".aiff"
        subprocess.run(["say", "-v", VOICE, "-o", aiff, r.get("spoken", r["text"])], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, out], check=True)
        os.remove(aiff)
        print(r["id"], f"{duration(out):.2f}s")


def real(source):
    with wave.open(source) as src:
        rate, width, ch = src.getframerate(), src.getsampwidth(), src.getnchannels()
        for cid, start, end in ((c["id"], c["start"], c["end"]) for c in REAL["clips"]):
            src.setpos(int(start * rate))
            frames = src.readframes(int((end - start) * rate))
            tmp = os.path.join(CLIPS, cid + ".src.wav")
            with wave.open(tmp, "wb") as w:
                w.setnchannels(ch); w.setsampwidth(width); w.setframerate(rate); w.writeframes(frames)
            out = os.path.join(CLIPS, cid + ".wav")
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", tmp, out], check=True)
            os.remove(tmp)
            print(cid, f"{duration(out):.2f}s")


if __name__ == "__main__":
    os.makedirs(CLIPS, exist_ok=True)
    rows = [json.loads(l) for l in open(os.path.join(ROOT, "manifest.jsonl")) if l.strip()]
    synth(rows)
    source = os.path.expanduser(REAL["source"] or "")
    if REAL["source"] and os.path.exists(source):
        real(source)
    else:
        print("no real recording found", file=sys.stderr)
