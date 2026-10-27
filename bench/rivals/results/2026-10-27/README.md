# Lip Service vs Willow vs Wispr Flow, 2026-10-27

This run times each app from the moment you let go of its key to the moment its text lands in a text box. Each app ran the way people use it, with its own hold key, audio through a microphone, and its own paste.

## Setup

- Machine: Mac mini, Apple M4, 24 GB, macOS 26.6.2, on a home internet connection. All three apps ran at the same time in one macOS user account, each on its own hold key.
- Apps:
  - Lip Service 1.0.0, the public release, on fn.
  - Wispr Flow 1.6.1264, Free plan, on Right Option.
  - Willow Voice 2.6.9, Pro plan with the Frontier Pro model, on Right Command. Screen context was on, as Willow recommends.
- Dictionary: each app had the same 13 names from the test clips, with no misheard spellings. The names are Hermes, ProfitPilot, Nective, HubSpot, Beehiiv, Obsidian, TaskNotes, Tailscale, Claude, Codex, Granola, Infisical, and Executor. Willow and Wispr Flow also kept the words already in the account's dictionary.
- Input: the 15 clips from `bench/make_clips.py` (378 words), played into the BlackHole 2ch virtual microphone. Each app used it as its microphone.
- Driver: [`RivalBench.swift`](../../RivalBench.swift). Each trial goes like this:
  1. RivalBench focuses its own empty text view and holds the app's key.
  2. It waits 0.6 s, plays the clip, waits 0.4 s, and lets go.
  3. It records the time from key-up to the last change in its text view, once the text has stayed the same for 1.5 s.

  The time includes each app's transcription, any network round trip, and its paste.
- Order: 5 rounds × 15 clips × 3 apps, 225 trials in all. Within each clip the apps take turns, and the order rotates by clip and round. A short warm-up of 2 clips per app ran first and is not scored.

## Results

`python3 bench/rivals_score.py bench/rivals/results/2026-10-27/final.jsonl`:

| App | Trials | Errors | Median | p95 | Max | Round medians | Words wrong | Names right per round |
|---|---|---|---|---|---|---|---|---|
| Lip Service | 75 | 0 | 0.212 s | 0.302 s | 0.343 s | 0.188 to 0.234 s | 1.3% | 19 of 20 |
| Willow (Pro) | 75 | 0 | 0.370 s | 0.534 s | 0.617 s | 0.350 to 0.389 s | 2.4% | 19 of 20 |
| Wispr Flow (Free) | 75 | 0 | 0.388 s | 0.640 s | 0.819 s | 0.371 to 0.411 s | 2.2% | 20 of 20 |

Lip Service's slowest round median (0.234 s) is below the fastest round medians of both rivals (0.350 s and 0.371 s).

The files:

- `main.jsonl` is the untouched run.
- One Wispr Flow trial in round 1 failed before the key was pressed. RivalBench could not take focus because Wispr Flow's window was in front at startup. That trial was re-run on its own, and the result (0.340 s) is in `makeup.jsonl`.
- `final.jsonl` is `main.jsonl` with the re-run in place of the failed row.
- `plan-main.json` is the plan RivalBench ran, and `final-summary.json` is the scorer's output.

## Accuracy is a tie

The word error rates mostly measure formatting, not hearing:

- Willow and Wispr Flow turned "First… Second… And third…" (clip u12) into a numbered list. That counts as 4 errors per round for each of them.
- The scorer ignores "um" and "uh", but the u14 reference keeps "you know", and all three apps drop it. Willow and Wispr Flow also drop "so".
- Willow writes "nine" as "9:00" in u11, which counts as one error.
- Misheard words per round:
  - Lip Service, 2: "note" for node, and "in-physical" for Infisical.
  - Willow, 1: "physical" for Infisical.
  - Wispr Flow, 0 to 2: "pull requests" and "base views".

The only claim this run supports is speed.

## Not covered

- Real microphones and real voices. The clips are synthetic, and they are Lip Service's own test set, which it was developed against. That can favor its accuracy. It does not change the timing.
- Other networks or Macs. The rivals' times depend on the internet connection.
- Willow's Free plan and Wispr Flow Pro.
