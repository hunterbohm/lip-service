#!/bin/bash
# Fills FluidAudio's model cache with curl, at the commits and with the file sizes and SHA-256 hashes listed in
# scripts/models.lock, which scripts/pin-models.py writes. Builds, tests and benchmarks on the Mac mini run over SSH,
# where FluidAudio's URLSession downloader traps. The installed app downloads and checks the same files itself on
# first launch. Each model folder is assembled under a temporary name and renamed into place, because FluidAudio
# treats a folder as complete as soon as its bundle directories exist. An existing folder is checked and left as it
# is. Safe to rerun. MODELS_DIR replaces FluidAudio's models folder.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/scripts/models.lock"
models="${MODELS_DIR:-$HOME/Library/Application Support/FluidAudio/Models}"
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

fetch() {
    local repo="$1" commit="$2" folder="$3" entries="$4"
    local final="$models/$folder"
    if [[ -d "$final" ]]; then
        if check "$final" "$entries"; then
            printf '%s already present and checked.\n' "$folder"
            return
        fi
        printf '%s does not match %s at %s. Remove it and run this again.\n' "$final" "$repo" "${commit:0:12}" >&2
        exit 1
    fi
    local staging="$models/.$folder.partial"
    mkdir -p "$staging"
    local size digest path out
    while read -r size digest path; do
        out="$staging/$path"
        mkdir -p "$(dirname "$out")"
        if [[ -f "$out" && "$(stat -f %z "$out")" == "$size" && "$(sha256 "$out")" == "$digest" ]]; then continue; fi
        if [[ "$size" == 0 ]]; then : > "$out"; else
            curl -fsSL --retry 3 -o "$out.part" "https://huggingface.co/$repo/resolve/$commit/$path"
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
repo="" commit="" folder=""
while read -r kind first second third; do
    case "$kind" in
        '#'*) ;;
        model)
            if [[ -n "$folder" ]]; then fetch "$repo" "$commit" "$folder" "$entries"; fi
            repo="$first" commit="$second" folder="$third"
            : > "$entries"
            ;;
        *) printf '%s %s %s\n' "$kind" "$first" "$second" >> "$entries" ;;
    esac
done < "$lock"
fetch "$repo" "$commit" "$folder" "$entries"
