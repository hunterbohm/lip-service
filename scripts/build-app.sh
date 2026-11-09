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
commit="$(git -C "$root" describe --always --dirty)"
build_number="$(git -C "$root" rev-list --count HEAD)"

# SwiftPM compiles the build directory's path into the binary, through FluidAudio's resource accessor. A neutral
# path keeps the builder's home folder out of a released app. A short hash of the checkout's path gives each
# checkout its own folder, so two builds at once cannot package each other's binary.
scratch="/tmp/lip-service-build-$(printf '%s' "$root" | shasum -a 256 | cut -c1-10)"
mkdir -p "$scratch"
if [[ ! -O "$scratch" ]]; then
    printf '%s belongs to another user. Remove it or build from another account.\n' "$scratch" >&2
    exit 1
fi
swift build --package-path "$root" --scratch-path "$scratch" -c release
binary_dir="$(swift build --package-path "$root" --scratch-path "$scratch" -c release --show-bin-path)"

mkdir -p "$root/dist"
staging="$(mktemp -d "$root/dist/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
contents="$staging/$bundle/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary_dir/Dictation" "$contents/MacOS/Dictation"
cp "$root/Info.plist" "$contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$contents/Info.plist"
for resource in selftest.wav start.wav stop.wav cancel.wav talk-start.wav talk-end.wav AppIcon.icns; do
    cp "$root/Resources/$resource" "$contents/Resources/$resource"
done

# The licenses of the code compiled into the app. Of FluidAudio's ThirdPartyLicenses, the linked ones cover code in
# the FluidAudio product. The others cover the NemoTextProcessing binary target, which fetch-deps.sh removes,
# text-to-speech model files that the app does not ship, and the LuxTTS English G2P tables. Those tables are derived
# from espeak-ng output (GPL-3.0) and live in FluidAudio's separate LuxTtsG2pResources resource bundle, which the
# TTS trait links but which this script never copies into the app. The check below stops the build if one is copied.
# Live talk downloads its voice's model files at run time, under their own licenses, and the app ships none of them.
fluid="$root/Vendor/FluidAudio"
linked=(fastcluster-LICENSE.md vbx-LICENSE.md JapaneseG2P-LICENSE.md)
not_linked=(NemoTextProcessing-LICENSE.md KokoroANE-v3 KokoroAneSpanishFrenchG2P-LICENSE.md LuxTtsEnglishG2P-LICENSE.md)
for entry in "$fluid"/ThirdPartyLicenses/*; do
    if [[ " ${linked[*]} ${not_linked[*]} " != *" ${entry##*/} "* ]]; then
        printf 'Check whether FluidAudio ThirdPartyLicenses/%s covers linked code, then list it in %s.\n' "${entry##*/}" "$0" >&2
        exit 1
    fi
done
licenses="$contents/Resources/Licenses"
mkdir -p "$licenses/FluidAudio/ThirdPartyLicenses"
cp "$root/LICENSE" "$licenses/LICENSE"
cp "$fluid/LICENSE" "$licenses/FluidAudio/LICENSE"
for name in "${linked[@]}"; do cp "$fluid/ThirdPartyLicenses/$name" "$licenses/FluidAudio/ThirdPartyLicenses/$name"; done

# The app must not ship FluidAudio's LuxTTS G2P tables (derived from GPL-3.0 espeak-ng output), which the TTS trait
# builds into a resource bundle beside the binary. Only the files copied above go into the app, so none should be here.
if find "$staging/$bundle" \( -name '*.tsv.zz' -o -name 'luxtts_*' -o -name '*LuxTtsG2pResources*' \) | grep -q .; then
    printf 'The app bundle holds LuxTTS G2P files, which are not MIT-compatible. Remove them from %s.\n' "$bundle" >&2
    exit 1
fi

# The umask above keeps build files private, but every account on the Mac must be able to open the app.
chmod -R go+rX "$staging/$bundle"
"$root/scripts/sign.sh" "$staging/$bundle" com.hunterbohm.dictation "$root/Resources/Dictation.entitlements"
codesign --verify --strict --verbose=2 "$staging/$bundle"
if [[ -e "$app" ]]; then mv "$app" "$staging/old.app"; fi
mv "$staging/$bundle" "$app"
printf '%s (build %s, %s)\n' "${app#"$root/"}" "$build_number" "$commit"
