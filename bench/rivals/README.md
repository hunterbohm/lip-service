# Rival benchmark

Measures Lip Service against other hold-to-talk dictation apps the way a person uses them. RivalBench holds an
app's hotkey, plays one of the 15 synthetic clips into a virtual microphone, lets go, and times how long the text
takes to land in its own text view. Every app gets the same clips, the same hold timing, and the same 13 names in
its dictionary, with no misheard spellings.

## Setup

1. Install BlackHole 2ch (`brew install --cask blackhole-2ch`, then `sudo killall coreaudiod`) and make it each
   app's microphone. Keep the speakers as the default output, so start and stop sounds stay out of the recording.
2. Give each app a different hold-to-talk key (`fn`, `rightoption`, `rightcommand`, `rightcontrol`) so all of them
   can stay running and the trials can interleave.
3. Add these names to each app's dictionary: Hermes, ProfitPilot, Nective, HubSpot, Beehiiv, Obsidian, TaskNotes,
   Tailscale, Claude, Codex, Granola, Infisical, Executor.
4. `bench/rivals/build.sh` builds `dist/RivalBench.app`. It needs Accessibility to press keys.

## Run

Write a plan and launch the binary inside the logged-in desktop session:

```json
{"clips": "bench/clips", "out": "bench/results/rivals.jsonl", "ids": ["u01", "u02"],
 "targets": [{"name": "Lip Service", "key": "fn"}, {"name": "Wispr Flow", "key": "rightoption"}],
 "rounds": [0, 1, 2, 3, 4, 5], "device": "BlackHole 2ch",
 "prerollS": 0.6, "tailS": 0.4, "settleS": 1.5, "timeoutS": 15, "gapS": 1.0}
```

For each round and clip, the apps take turns, and the order rotates so warm-up and drift favor none of them.
Round 0 is warm-up and is not scored. Results append one JSON line per trial.

`python3 bench/rivals_score.py bench/results/rivals.jsonl` prints word error rate and name hits on the synthetic
clips, and release-to-text p50, p95, max, and the spread of per-round medians for each app.

## What the time includes

Release-to-text runs from the key-up event to the last change in the text view. It includes the app's
transcription, any network round trip, and its paste. A trial counts as an error if no text arrives within
`timeoutS`, text arrives before release, or another app takes focus during the trial.

## Results

The 2026-10-27 run against Willow and Wispr Flow, with its raw results, is in [results/2026-10-27](results/2026-10-27).
