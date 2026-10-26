#!/bin/bash
# Runs the DictationCore tests with swift-testing from the Command Line Tools, so no Xcode and no FluidAudio
# build is needed. Fails first if the pure package imports a framework that would tie it to hardware or models.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="$root/DictationCore"

if grep -rnE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(AppKit|AVFoundation|CoreGraphics|FluidAudio)\b' "$package_dir/Sources"; then
    printf 'DictationCore/Sources must not import AppKit, AVFoundation, CoreGraphics or FluidAudio.\n' >&2
    exit 1
fi

mkdir -p "$root/.tmp"
export TMPDIR="$root/.tmp"
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.cache/swift"
arguments=(--disable-sandbox --disable-xctest --package-path "$package_dir" --scratch-path "$root/.build/core-tests"
    --cache-path "$root/.cache" --config-path "$root/.config" --security-path "$root/.security")
frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == /Library/Developer/CommandLineTools && -d "$frameworks/Testing.framework" ]]; then
    arguments+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks/../usr/lib")
fi
swift test "${arguments[@]}" "$@"
