#!/bin/bash
# Fills FluidAudio's model cache with curl, at the commits and with the file sizes and SHA-256 hashes listed in
# scripts/models.lock, which scripts/pin-models.py writes. Builds, tests and benchmarks on the Mac mini run over SSH,
# where FluidAudio's URLSession downloader traps. The installed app downloads and checks the same files itself on
# first launch. Each model folder is assembled under a temporary name and renamed into place, because FluidAudio
# treats a folder as complete as soon as its bundle directories exist. An existing folder is checked and left as it
# is. Safe to rerun. MODELS_DIR replaces FluidAudio's models folder.
# --voice also fetches live talk's on-Mac voice pack into FluidAudio's text-to-speech models folder, or VOICES_DIR,
# as `--test-talk` over SSH needs. Only the pack's folder inside its repository is assembled and renamed into place.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/scripts/models.lock"
models="${MODELS_DIR:-$HOME/Library/Application Support/FluidAudio/Models}"
voices="${VOICES_DIR:-$HOME/.cache/fluidaudio/Models}"
with_voice=0
case "${1:-}" in
    "") ;;
    --voice) with_voice=1 ;;
    *) printf 'usage: %s [--voice]\n' "$0" >&2; exit 2 ;;
esac
mkdir -p "$models"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Checks the files of the model whose lines are in $2 against folder $1: size, hash, and no other file in a bundle.
check() {
    local folder="$1" entries="$2" size digest path bad=0 bundle
    while read -r size digest path; do
        if [[ ! -f "$folder/$path" || -L "$folder/$path" ]]; then
            printf '%s is missing.\n' "$path" >&2; bad=1
        elif [[ "$(stat -f %z "$folder/$path")" != "$size" || "$(sha256 "$folder/$path")" != "$digest" ]]; then
            printf '%s does not match the pinned file.\n' "$path" >&2; bad=1
        fi
    done < "$entries"
    for bundle in $(cut -d' ' -f3 "$entries" | cut -d/ -f1 | grep '\.mlmodelc$' | sort -u); do
        while read -r path; do
            awk -v p="$path" '$3 == p { found = 1 } END { exit !found }' "$entries" \
                || { printf '%s should not be there.\n' "$path" >&2; bad=1; }
        done < <(cd "$folder" && find "$bundle" ! -type d)
    done
    return $bad
}

# A model is its whole repository, in $models/FOLDER. A voice is the folder SUBDIRECTORY of its repository, in
# $voices/FOLDER/SUBDIRECTORY, and its files are fetched from SUBDIRECTORY/PATH.
fetch() {
    local kind="$1" repo="$2" commit="$3" folder="$4" subdirectory="$5" entries="$6"
    local final="$models/$folder" remote=""
    if [[ "$kind" == voice ]]; then
        final="$voices/$folder/$subdirectory" remote="$subdirectory/"
        folder="$folder/$subdirectory"
    fi
    if [[ -d "$final" ]]; then
        if check "$final" "$entries"; then
            printf '%s already present and checked.\n' "$folder"
            return
        fi
        printf '%s does not match %s at %s. Remove it and run this again.\n' "$final" "$repo" "${commit:0:12}" >&2
        exit 1
    fi
    local staging="$(dirname "$final")/.$(basename "$final").partial"
    mkdir -p "$staging"
    local size digest path out
    while read -r size digest path; do
        out="$staging/$path"
        mkdir -p "$(dirname "$out")"
        if [[ -f "$out" && "$(stat -f %z "$out")" == "$size" && "$(sha256 "$out")" == "$digest" ]]; then continue; fi
        if [[ "$size" == 0 ]]; then : > "$out"; else
            curl -fsSL --retry 3 -o "$out.part" "https://huggingface.co/$repo/resolve/$commit/$remote$path"
            mv "$out.part" "$out"
        fi
        if [[ "$(stat -f %z "$out")" != "$size" || "$(sha256 "$out")" != "$digest" ]]; then
            rm -f "$out"
            printf '%s from %s at %s does not match the pinned file.\n' "$path" "$repo" "${commit:0:12}" >&2
            exit 1
        fi
    done < "$entries"
    check "$staging" "$entries" || exit 1
    mv "$staging" "$final"
    printf '%s fetched (%s).\n' "$folder" "$(du -sh "$final" | cut -f1)"
}

entries="$(mktemp)"
trap 'rm -f "$entries"' EXIT
current="" repo="" commit="" folder="" subdirectory=""
flush() {
    [[ -z "$current" ]] && return
    if [[ "$current" == model || "$with_voice" == 1 ]]; then fetch "$current" "$repo" "$commit" "$folder" "$subdirectory" "$entries"; fi
}
while read -r kind first second third fourth; do
    case "$kind" in
        '#'*) ;;
        model|voice)
            flush
            current="$kind" repo="$first" commit="$second" folder="$third" subdirectory="${fourth:-}"
            : > "$entries"
            ;;
        *) printf '%s %s %s\n' "$kind" "$first" "$second" >> "$entries" ;;
    esac
done < "$lock"
flush
