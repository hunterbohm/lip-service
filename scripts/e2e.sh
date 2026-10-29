#!/bin/bash
# End-to-end test of the built app binary: its self-test, then the bench over bench/clips scored against the
# bakeoff. Needs the models cached (scripts/fetch-models.sh), the clips (bench/make_clips.py), and
# "dist/Lip Service.app" (scripts/build-app.sh). ROUNDS, HOLD_CAP, GAP, WARM and PREVIEW override the bench
# settings. MODELS_DIR runs both on a copy of FluidAudio's models folder.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
binary="${DICTATION_APP:-$root/dist/Lip Service.app}/Contents/MacOS/Dictation"
if [[ ! -x "$binary" ]]; then
    printf 'No app binary at %s. Run scripts/build-app.sh first.\n' "$binary" >&2
    exit 1
fi
shopt -s nullglob
clips=("$root"/bench/clips/*.wav)
if [[ ${#clips[@]} -eq 0 ]]; then
    printf 'No clips in bench/clips. Run bench/make_clips.py first.\n' >&2
    exit 1
fi

models=()
[[ -n "${MODELS_DIR:-}" ]] && models=(--models "$MODELS_DIR")

"$binary" --self-test ${models[@]+"${models[@]}"}

mkdir -p "$root/bench/results"
results="$root/bench/results/e2e-$(date +%Y%m%d-%H%M%S).jsonl"
"$binary" --bench --rounds "${ROUNDS:-1}" --hold-cap "${HOLD_CAP:-15}" --gap "${GAP:-0}" --warm "${WARM:-on}" \
    --preview "${PREVIEW:-on}" ${models[@]+"${models[@]}"} "${clips[@]}" > "$results"
printf 'Bench results in %s.\n' "${results#"$root/"}"
python3 -I -B "$root/bench/e2e_score.py" "$results"
