#!/bin/bash
# Checks, with no network, that the speech-model download refuses paths that leave the model folder and skips
# files the app did not ask for. Compiles the guard that scripts/fetch-deps.sh adds to FluidAudio next to a small
# checker and runs it. When FluidAudio is vendored, also checks that the vendored copy is that same file and that
# ModelHub calls it where the files are chosen and where they are written.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/scripts/download-guard"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

mkdir -p "$root/.cache/clang"
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
swiftc -O -module-name DownloadGuardCheck -o "$build/check" "$guard/DownloadGuard.swift" "$guard/main.swift"
"$build/check"

download="$root/Vendor/FluidAudio/Sources/FluidAudio/Shared/Download"
if [[ ! -d "$download" ]]; then
    echo "FluidAudio is not vendored, so the wiring was not checked."
    exit 0
fi
fail() { echo "FAIL  $1" >&2; exit 1; }
cmp -s "$guard/DownloadGuard.swift" "$download/DownloadGuard.swift" || fail "the vendored DownloadGuard.swift differs from scripts/download-guard"
[[ "$(grep -c 'DownloadGuard.vet(' "$download/ModelHub.swift")" == 2 ]] || fail "ModelHub should vet the listing in both downloads"
[[ "$(grep -c 'DownloadGuard.destination(of:' "$download/ModelHub.swift")" == 2 ]] || fail "ModelHub should check the destination in both downloads"
! grep -nE 'appendingPathComponent\((localPath|file\.path)\)' "$download/ModelHub.swift" || fail "ModelHub still joins a server path without the guard"
! grep -nE 'environment\["(HF_TOKEN|HUGGING_FACE_HUB_TOKEN|HUGGINGFACEHUB_API_TOKEN)"\]' "$download/HFClient.swift" || fail "HFClient still reads a token from the environment"
! grep -nE 'environment\["(MODEL_)?REGISTRY_URL"\]' "$download/../../ModelRegistry.swift" || fail "ModelRegistry still reads a registry from the environment"
echo "pass  the vendored FluidAudio is wired to the guard"
