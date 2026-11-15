#!/bin/bash
# Runs inside a hidden Mac copy. scripts/hidden-mac-verify.sh copies it there and starts it; do not run it on a Mac
# someone uses. Everything it prints goes to ~/ls-verify/out, and ~/ls-verify/out/done appears when it ends.
# Env: ROUNDS (rounds of the busy churn run), CYCLES (device changes in the busy run), SOAK_ROUNDS (rounds of the run with no
# churn), IDLE_SECONDS, SKIP_MODELS=1.
set -u
work="$HOME/ls-verify"
out="$work/out"
app="$work/app/Lip Service.app"
bin="$app/Contents/MacOS/Dictation"
churn="$work/audio-churn"
reports="$HOME/Library/Logs/DiagnosticReports"
rounds="${ROUNDS:-100}"
cycles="${CYCLES:-200}"
soak_rounds="${SOAK_ROUNDS:-1500}"
idle_seconds="${IDLE_SECONDS:-45}"
mkdir -p "$out"
: > "$out/summary.txt"

say() { printf '%s\n' "$*" | tee -a "$out/summary.txt"; }
crash_count() { ls "$reports"/Dictation-* "$reports"/Retired/Dictation-* 2>/dev/null | wc -l | tr -d ' '; }
finish() { touch "$out/done"; }
trap finish EXIT

# macOS asks for the microphone with a dialog that needs a click, and this copy has System Integrity Protection off,
# so the grant is written to the permission database.
grant_microphone() {
    local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    sqlite3 "$db" "delete from access where client='com.hunterbohm.dictation' and service='kTCCServiceMicrophone'"
    sqlite3 "$db" "insert into access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) values ('kTCCServiceMicrophone', 'com.hunterbohm.dictation', 0, 2, 2, 1, 0, strftime('%s','now'))"
}

# Starts the app through LaunchServices, because the microphone grant belongs to the app and not to an ssh session.
mic() {
    local name="$1"
    shift
    rm -f "$out/$name.log"
    open -n -W --stdout "$out/$name.log" --stderr "$out/$name.log" "$app" --args --mic-start "$@"
}

rounds_in() { grep -c '"round"' "$1" 2>/dev/null || true; }
silent_in() { grep -c '"audio":0,' "$1" 2>/dev/null || true; }
# The value of a number field in the round lines of a log, in round order.
field_in() { sed -n "s/.*\"$2\":\([0-9.]*\).*/\1/p" "$1" 2>/dev/null; }
# The default input changes the churn tool reports. A churn that failed or changed nothing proves nothing.
changes_in() { sed -n 's/.*default input changes \([0-9]*\).*/\1/p' "$1" 2>/dev/null | tail -1; }

rm -f "$reports"/Dictation-* "$reports"/Retired/Dictation-*
grant_microphone

if [[ "${SKIP_MODELS:-}" != 1 ]]; then
    if (cd "$work" && scripts/fetch-models.sh) > "$out/models.log" 2>&1; then say "models: ready"; else say "models: FAIL (see models.log)"; fi
fi

"$bin" --list-inputs > "$out/inputs.log" 2>&1
say "inputs: $(grep -c . "$out/inputs.log") lines, $(grep '^default:' "$out/inputs.log")"

if "$bin" --self-test > "$out/selftest.log" 2>&1; then say "self-test: PASS ($(grep '^release to text' "$out/selftest.log"))"; else say "self-test: FAIL (see selftest.log)"; fi

before=$(crash_count)
mic smoke --rounds 5 --hold 0.6 --gap 0.4 --microphone default
heard=$(grep -c '"audio":0\.[0-9]' "$out/smoke.log" || true)
if [[ "$(rounds_in "$out/smoke.log")" == 5 && "$heard" == 5 ]]; then say "mic smoke: PASS (5 rounds, audio in $heard)"; else say "mic smoke: FAIL ($(rounds_in "$out/smoke.log") rounds, audio in $heard, see smoke.log)"; fi

before=$(crash_count)
mic soak --rounds "$soak_rounds" --hold 0.4 --gap 0.05 --microphone default
kept_first=$(field_in "$out/soak.log" kept | head -1)
kept_last=$(field_in "$out/soak.log" kept | tail -1)
rss_warm=$(field_in "$out/soak.log" rss | sed -n 50p)
rss_last=$(field_in "$out/soak.log" rss | tail -1)
rss_growth=$(awk -v a="${rss_warm:-0}" -v b="${rss_last:-0}" 'BEGIN { printf "%.1f", b - a }')
soak_detail="$soak_rounds rounds, engines kept $kept_first to $kept_last, memory $rss_warm to $rss_last MB, silent $(silent_in "$out/soak.log")"
if [[ "$(rounds_in "$out/soak.log")" == "$soak_rounds" && -n "$kept_last" && "$kept_last" == "$kept_first" \
    && "$(silent_in "$out/soak.log")" == 0 && "$(crash_count)" == "$before" ]] \
    && awk -v growth="$rss_growth" 'BEGIN { exit !(growth < 5) }'; then
    say "soak, no churn: PASS ($soak_detail)"
else
    say "soak, no churn: FAIL ($soak_detail, crash reports $(($(crash_count) - before)), see soak.log)"
fi

before=$(crash_count)
mic idle --rounds 1 --gap "$idle_seconds" --hold 1 --microphone default &
app_job=$!
sleep 5
"$churn" --cycles $((idle_seconds * 7)) --pause 100 --rates > "$out/idle-churn.log" 2>&1
churn_status=$?
wait "$app_job"
changes=$(changes_in "$out/idle-churn.log")
if [[ "$(rounds_in "$out/idle.log")" == 1 && "$(crash_count)" == "$before" && "$churn_status" == 0 && "${changes:-0}" -gt 0 ]]; then
    say "idle churn: PASS ($(tail -1 "$out/idle-churn.log"))"
else
    say "idle churn: FAIL (rounds $(rounds_in "$out/idle.log") of 1, crash reports $(($(crash_count) - before)), churn exit $churn_status, default input changes ${changes:-0}, see idle.log and idle-churn.log)"
fi

before=$(crash_count)
mic busy --rounds "$rounds" --hold 0.4 --gap 0.2 --microphone default &
app_job=$!
sleep 5
"$churn" --cycles "$cycles" --pause 250 --rates > "$out/busy-churn.log" 2>&1
churn_status=$?
wait "$app_job"
changes=$(changes_in "$out/busy-churn.log")
if [[ "$(rounds_in "$out/busy.log")" == "$rounds" && "$(crash_count)" == "$before" && "$churn_status" == 0 && "${changes:-0}" -gt 0 ]]; then
    say "busy churn: PASS ($rounds rounds, silent $(silent_in "$out/busy.log"), $(tail -1 "$out/busy-churn.log"))"
else
    say "busy churn: FAIL (rounds $(rounds_in "$out/busy.log") of $rounds, crash reports $(($(crash_count) - before)), churn exit $churn_status, default input changes ${changes:-0}, see busy.log and busy-churn.log)"
fi

say "crash reports on this copy: $(crash_count)"
