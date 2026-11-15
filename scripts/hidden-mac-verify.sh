#!/bin/bash
# Proves a Lip Service build works on a hidden Mac, a macOS VM on the mini that nobody watches. It builds the app (or
# takes one with --app), starts a fresh copy of the hidden Mac, installs the app there, grants the microphone, caches
# the speech models, then runs the self-test, a microphone smoke test, and two runs that start and stop the microphone
# while scripts/audio-churn.swift adds, removes and re-rates audio devices around it. It copies the results and any
# Dictation crash reports back, takes a screenshot, and always stops the copy. It mutes the copy first, so the tests
# make no sound on the mini.
#
# usage: scripts/hidden-mac-verify.sh [--job NAME] [--app PATH] [--rounds N] [--cycles N] [--results DIR] [--keep]
#                                     [--skip-models]
# Run it on the MacBook, or on the mini itself. HIDDEN_MAC_HOST names the mini's ssh host and hostname (default mini).
# Exits 0 when every check passes, 1 when one fails, 2 when the setup fails.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
job="ls-verify-$(printf '%04x' "$RANDOM")"
app=""
rounds=100
cycles=200
results=""
keep=0
skip_models=0
while (($#)); do
    case "$1" in
        --job) job="$2"; shift 2 ;;
        --app) app="$2"; shift 2 ;;
        --rounds) rounds="$2"; shift 2 ;;
        --cycles) cycles="$2"; shift 2 ;;
        --results) results="$2"; shift 2 ;;
        --keep) keep=1; shift ;;
        --skip-models) skip_models=1; shift ;;
        *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    esac
done
results="${results:-$root/.tmp/hidden-mac-verify/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$results"

mini="${HIDDEN_MAC_HOST:-mini}"
if [[ "$(hostname -s)" == "$mini" ]]; then
    host=""
    hm() { hidden-mac "$@"; }
    stage="/tmp/$job"
    mkdir -p "$stage"
    to_stage() { cp "$@" "$stage/"; }
    from_stage() { cp -R "$stage/$1" "$2"; }
else
    host="$mini"
    hm() { ssh "$host" "hidden-mac $(printf '%q ' "$@")"; }
    stage="/tmp/$job"
    ssh "$host" "mkdir -p '$stage'"
    to_stage() { scp -q -r "$@" "$host:$stage/"; }
    from_stage() { scp -q -r "$host:$stage/$1" "$2"; }
fi
vm() { hm "$job" exec "$@"; }

work=""
cleanup() {
    local code=$?
    [[ -z "$work" ]] || rm -rf "$work"
    if ((keep)); then
        printf 'The copy %s keeps running. Stop it with: hidden-mac stop %s\n' "$job" "$job" >&2
    else
        hm stop "$job" > /dev/null 2>&1 || printf 'Could not stop %s. Run: hidden-mac stop %s\n' "$job" "$job" >&2
    fi
    if [[ -n "$host" ]]; then ssh "$host" "rm -rf '$stage'" > /dev/null 2>&1 || true; else rm -rf "$stage"; fi
    exit "$code"
}
trap cleanup EXIT

work="$(mktemp -d)"

if [[ -z "$app" ]]; then
    [[ -d "$root/Vendor/FluidAudio" ]] || "$root/scripts/fetch-deps.sh"
    "$root/scripts/build-app.sh"
    app="$root/dist/Lip Service.app"
fi
[[ -d "$app" ]] || { printf 'No app at %s\n' "$app" >&2; exit 2; }
swiftc -O "$root/scripts/audio-churn.swift" -o "$work/audio-churn"
ditto -c -k --keepParent "$app" "$work/app.zip"
cp "$root/scripts/hidden-mac-vm.sh" "$root/scripts/fetch-models.sh" "$root/scripts/models.lock" "$work/"

to_stage "$work/audio-churn" "$work/app.zip" "$work/hidden-mac-vm.sh" "$work/fetch-models.sh" "$work/models.lock"
started=0
for attempt in 1 2 3; do
    if hm "$job" start; then started=1; break; fi
    sleep 30
done
((started)) || { printf 'The hidden Mac copy did not start.\n' >&2; exit 2; }

vm 'osascript -e "set volume with output muted"' > /dev/null
if [[ "$(vm 'osascript -e "output muted of (get volume settings)"' | tr -d '\r\n')" != true ]]; then
    printf 'The copy is not muted. Stopping before any sound plays.\n' >&2
    exit 2
fi

vm "rm -rf ~/ls-verify && mkdir -p ~/ls-verify/app ~/ls-verify/out ~/ls-verify/scripts"
for file in audio-churn app.zip hidden-mac-vm.sh; do hm "$job" cp "$stage/$file" ":ls-verify/$file" > /dev/null; done
for file in fetch-models.sh models.lock; do hm "$job" cp "$stage/$file" ":ls-verify/scripts/$file" > /dev/null; done
vm "cd ~/ls-verify && chmod +x audio-churn hidden-mac-vm.sh scripts/fetch-models.sh && ditto -x -k app.zip app && ls app"

skip=""
((skip_models)) && skip="SKIP_MODELS=1"
vm "cd ~/ls-verify && ROUNDS=$rounds CYCLES=$cycles $skip nohup ./hidden-mac-vm.sh > out/run.log 2>&1 < /dev/null & echo started" > /dev/null
printf 'Running on %s. This takes about 5 minutes, or 15 on a copy that has no speech models yet.\n' "$job"

waited=0
until vm "test -e ~/ls-verify/out/done" > /dev/null 2>&1; do
    sleep 10
    waited=$((waited + 10))
    if ((waited > 2400)); then printf 'Timed out after 40 minutes.\n' >&2; break; fi
done

mkdir -p "$results/out" "$results/crash-reports"
vm "cat ~/ls-verify/out/summary.txt" > "$results/summary.txt" 2>&1 || true
for file in $(vm "ls ~/ls-verify/out" 2> /dev/null | tr -d '\r'); do
    vm "cat ~/ls-verify/out/$file" > "$results/out/$file" 2> /dev/null || true
done
for report in $(vm 'ls ~/Library/Logs/DiagnosticReports/Dictation-* ~/Library/Logs/DiagnosticReports/Retired/Dictation-* 2>/dev/null' | tr -d '\r'); do
    vm "cat '$report'" > "$results/crash-reports/$(basename "$report")" 2> /dev/null || true
done
hm "$job" screenshot "$stage/screen.png" > /dev/null 2>&1 && from_stage screen.png "$results/screen.png" || true

cat "$results/summary.txt"
printf 'Results: %s\n' "$results"
if grep -q 'FAIL' "$results/summary.txt" || [[ -n "$(ls -A "$results/crash-reports")" ]] || ! grep -q 'busy churn' "$results/summary.txt"; then
    exit 1
fi
