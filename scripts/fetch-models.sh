#!/bin/bash
# Fills FluidAudio's model cache with curl. Builds, tests and benchmarks on the Mac mini run over SSH,
# where FluidAudio's URLSession downloader traps. The installed app downloads the same files itself on
# first launch. Each model folder is assembled under a temporary name and renamed into place, because
# FluidAudio treats a folder as complete as soon as its bundle directories exist. Safe to rerun.
set -euo pipefail
models="$HOME/Library/Application Support/FluidAudio/Models"
mkdir -p "$models"

fetch() {
    local repo="$1" folder="$2"
    shift 2
    local final="$models/$folder"
    if [[ -d "$final" ]]; then
        printf '%s already present.\n' "$folder"
        return
    fi
    local staging="$models/.$folder.partial"
    mkdir -p "$staging"
    curl -fsSL --retry 3 "https://huggingface.co/api/models/$repo/tree/main?recursive=true" \
        | python3 -I -c '
import json, sys
bundles = tuple(b + "/" for b in sys.argv[1:])
for item in json.load(sys.stdin):
    p = item["path"]
    if item["type"] != "file":
        continue
    if p.startswith(bundles) or ("/" not in p and p.endswith((".json", ".txt"))):
        print(item.get("size", 0), p)
' "$@" > "$staging/.files"
    [[ -s "$staging/.files" ]] || { printf 'No files listed for %s.\n' "$repo" >&2; exit 1; }
    while read -r size path; do
        local out="$staging/$path"
        mkdir -p "$(dirname "$out")"
        if [[ -f "$out" && "$(stat -f %z "$out")" == "$size" ]]; then continue; fi
        if [[ "$size" == 0 ]]; then : > "$out"; continue; fi
        curl -fsSL --retry 3 -o "$out.part" "https://huggingface.co/$repo/resolve/main/$path"
        [[ "$(stat -f %z "$out.part")" == "$size" ]] || { printf 'Size mismatch for %s.\n' "$path" >&2; exit 1; }
        mv "$out.part" "$out"
    done < "$staging/.files"
    for bundle in "$@"; do
        [[ -f "$staging/$bundle/coremldata.bin" ]] || { printf '%s is missing coremldata.bin.\n' "$bundle" >&2; exit 1; }
    done
    rm "$staging/.files"
    mv "$staging" "$final"
    printf '%s fetched (%s).\n' "$folder" "$(du -sh "$final" | cut -f1)"
}

fetch FluidInference/parakeet-tdt-0.6b-v2-coreml parakeet-tdt-0.6b-v2 \
    Preprocessor.mlmodelc Encoder.mlmodelc Decoder.mlmodelc JointDecision.mlmodelc
fetch FluidInference/parakeet-ctc-110m-coreml parakeet-ctc-110m-coreml \
    MelSpectrogram.mlmodelc AudioEncoder.mlmodelc
