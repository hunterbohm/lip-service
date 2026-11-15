---
name: verify
description: Prove a Lip Service change works on the hidden Mac, a macOS VM on the mini. Use before you call work done when it touches the microphone, audio devices, the speech engine, start-up, or anything else the app does at run time. Never test on Hunter's own screens.
---

# Verify Lip Service on the hidden Mac

Hunter's MacBook and the mini's own screen are his. Test on your own copy of the hidden Mac instead.

## Run it

From the repo, on the MacBook or on the mini:

```sh
scripts/hidden-mac-verify.sh
```

Run it as a background command and wait for it. It takes about 20 minutes, or 30 on a copy with no speech models yet.

It builds the app (`--app PATH` uses one you built), starts a fresh copy of the hidden Mac, mutes the copy, installs the app, grants the microphone, and runs:

- `--self-test`: the speech model hears the bundled clip.
- A microphone smoke test: 5 start and stop rounds, each must record audio.
- A soak: 1500 start and stop rounds of 0.4 s, 0.05 s apart, with no device change. It fails if the number of engines the app keeps grows, if its memory grows 5 MB or more after round 50, or if a round records nothing.
- An idle churn: the app waits with its microphone ready while `scripts/audio-churn.swift` adds and removes audio devices, moves the default input, and changes sample rates.
- A busy churn: the same, while the microphone starts and stops 100 times.

Options: `--rounds N` and `--cycles N` make the busy churn longer, `--soak-rounds N` sets the soak, `--results DIR` moves the results, `--skip-models` skips the model download, `--job NAME` names the copy.

## Read the result

- The last lines are one `PASS` or `FAIL` per check. A churn check passes only when the churn tool exited 0, changed the default input at least once, and the app ended within 150 s of the churn (`hung 1` means it did not; its stacks are in `out/hung-sample.txt`, and it was killed). Exit 0 means all passed, 1 means a check failed or a Dictation crash report appeared, 2 means the setup failed.
- The results folder (printed at the end, under `.tmp/hidden-mac-verify/`) holds `summary.txt`, `out/*.log` for each check, `crash-reports/*.ips`, and `screen.png`.
- For a crash report, read `exception`, `asi`, and the thread with `"triggered": true`. Then the app's own threads: the microphone queue is `com.hunterbohm.dictation.microphone`.
- `silent` in the busy churn counts rounds that recorded nothing. A few are normal, because the churn removes the device the app was using. A jump after your change is worth a look.

## Keep the test silent

The app plays its start and stop sounds, and the copy's sound comes out of the mini's speakers. The script mutes the copy before anything plays, with `osascript -e "set volume with output muted"` run in the copy, and stops if the mute did not take. If you start a copy by hand, run that first. Mute only your copy: leave the mini's own volume alone, and never unmute the copy.

## Stop the copy

The script stops its copy on exit, also on failure. If it was killed, run `ssh mini hidden-mac list`, then `ssh mini hidden-mac stop JOB`. A forgotten copy blocks other jobs. Only two copies run at once.

## What it cannot show

The hidden Mac has one virtual microphone. It has no Bluetooth and no second device at another sample rate, so AirPods and the wait in `settleAfterPicking` are not covered. A pass means no crash in that run, which is weak proof for a rare race. Say so in your report.

For other checks, drive the copy yourself: `hidden-mac JOB exec CMD`, `hidden-mac JOB cp`, `hidden-mac JOB screenshot FILE`, and `hidden-mac JOB do` for clicks. Start the app through `open`, not from ssh, because the microphone grant belongs to the app.
