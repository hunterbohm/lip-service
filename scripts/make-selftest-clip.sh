#!/bin/bash
# Regenerates Resources/selftest.wav, the clip that `Dictation --self-test` transcribes. It speaks two
# vocabulary terms the way the engine mishears them, so the self-test fails unless boosting or an alias fires.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$root/Resources"
say -v Samantha -o "$scratch/selftest.aiff" "Ask Profit Pilot to send the newsletter from Bee hive on Friday."
afconvert -f WAVE -d LEI16@16000 -c 1 "$scratch/selftest.aiff" "$root/Resources/selftest.wav"
printf 'Wrote Resources/selftest.wav (%s).\n' "$(afinfo "$root/Resources/selftest.wav" | awk '/estimated duration/ {print $3 " s"}')"
