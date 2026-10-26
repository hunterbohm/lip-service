#!/bin/bash
# Builds "dist/Lip Service.app" from a release build and signs it with the local certificate, so macOS keeps the
# Microphone and Accessibility grants across rebuilds. The new bundle is assembled beside the old one and
# renamed into place, because copying over the binary of a running app makes the kernel kill it for an
# invalid signature.
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="Lip Service.app"
app="$root/dist/$bundle"
version="$(git -C "$root" describe --always --dirty)"
build_number="$(git -C "$root" rev-list --count HEAD)"

swift build --package-path "$root" -c release
binary_dir="$(swift build --package-path "$root" -c release --show-bin-path)"

mkdir -p "$root/dist"
staging="$(mktemp -d "$root/dist/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
contents="$staging/$bundle/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary_dir/Dictation" "$contents/MacOS/Dictation"
cp "$root/Info.plist" "$contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$contents/Info.plist"
for resource in selftest.wav start.wav stop.wav cancel.wav AppIcon.icns; do
    cp "$root/Resources/$resource" "$contents/Resources/$resource"
done
"$root/scripts/sign.sh" "$staging/$bundle" com.hunterbohm.dictation
codesign --verify --strict --verbose=2 "$staging/$bundle"
if [[ -e "$app" ]]; then mv "$app" "$staging/old.app"; fi
mv "$staging/$bundle" "$app"
printf '%s (%s)\n' "${app#"$root/"}" "$version"
