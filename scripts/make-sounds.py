#!/usr/bin/env python3
"""Writes the bar's start, stop, and cancel cues as 44.1 kHz mono WAV files into the folder given."""
import math
import struct
import sys
import wave
from pathlib import Path

RATE = 44_100
PEAK = 10 ** (-16 / 20)


def note(freq, start, length, gain=1.0):
    return (freq, start, length, gain)


def render(notes, seconds):
    out = [0.0] * int(RATE * seconds)
    for freq, start, length, gain in notes:
        first = int(start * RATE)
        for i in range(int(length * RATE)):
            t = i / RATE
            attack = min(1.0, t / 0.004)
            decay = math.exp(-t / (length / 4))
            tone = math.sin(2 * math.pi * freq * t) + 0.18 * math.sin(4 * math.pi * freq * t)
            if first + i < len(out):
                out[first + i] += gain * attack * decay * tone
    top = max(abs(s) for s in out) or 1.0
    return [s / top * PEAK for s in out]


def write(path, samples):
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(struct.pack("<h", round(s * 32767)) for s in samples))


CUES = {
    "start": ([note(659.3, 0, 0.11), note(987.8, 0.045, 0.16)], 0.22),
    "stop": ([note(987.8, 0, 0.11), note(659.3, 0.045, 0.16)], 0.22),
    "cancel": ([note(493.9, 0, 0.12, 0.8)], 0.14),
}

if __name__ == "__main__":
    folder = Path(sys.argv[1])
    folder.mkdir(parents=True, exist_ok=True)
    for name, (notes, seconds) in CUES.items():
        write(folder / f"{name}.wav", render(notes, seconds))
        print(folder / f"{name}.wav")
