#!/bin/bash
# Builds the tagged HEAD as a Developer ID signed, Apple-notarized "Lip Service.app", zips it as
# Lip-Service-<version>.zip, and uploads it to that tag's GitHub release. Usage: release.sh [--no-upload]
# Run it on a Mac with the Developer ID certificate in its keychain, under `infisical run --` (see docs/reference.md):
#   LS_SIGN_IDENTITY   the certificate's name, "Developer ID Application: <company> (<team id>)"
#   LS_TEAM_ID         the ten-character team id; the app only installs updates signed by the team it is signed by
#   Notarization, one of:  LS_NOTARY_PROFILE (a `notarytool store-credentials` keychain profile), or
#                          LS_NOTARY_KEY (the App Store Connect API key's .p8 text), LS_NOTARY_KEY_ID, LS_NOTARY_ISSUER
# Each name also reads the same name with HEREBY_ in place of LS_ when the LS_ one is unset, which is how the shared
# secret store names them. It writes the zip to LS_RELEASE_OUT (default dist/release-out/<tag>). --no-upload stops there.
# Uploading needs a clean clone with HEAD on the release tag, vX.Y.Z for the version in Info.plist, and gh logged in.
set -euo pipefail
umask 022
upload=1
for argument in "$@"; do
    case "$argument" in
        --no-upload) upload=0 ;;
        *) printf 'usage: release.sh [--no-upload]\n' >&2; exit 2 ;;
    esac
done
root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id=com.hunterbohm.dictation

for name in SIGN_IDENTITY TEAM_ID NOTARY_PROFILE NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER; do
    ls_name="LS_$name"; shared_name="HEREBY_$name"
    [[ -n "${!ls_name:-}" ]] || export "$ls_name=${!shared_name:-}"
done
missing=()
for name in LS_SIGN_IDENTITY LS_TEAM_ID; do [[ -n "${!name}" ]] || missing+=("$name"); done
if [[ -z "$LS_NOTARY_PROFILE" ]]; then
    for name in LS_NOTARY_KEY LS_NOTARY_KEY_ID LS_NOTARY_ISSUER; do [[ -n "${!name}" ]] || missing+=("$name (or LS_NOTARY_PROFILE)"); done
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'Not releasing: missing %s. Run it under `infisical run --`; see docs/reference.md.\n' "${missing[*]}" >&2
    exit 1
fi
if [[ ! "$LS_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then printf 'LS_TEAM_ID is not a team id.\n' >&2; exit 1; fi
if [[ "$LS_SIGN_IDENTITY" != "Developer ID Application: "*"($LS_TEAM_ID)" ]]; then
    printf 'LS_SIGN_IDENTITY must be a Developer ID Application certificate of team %s.\n' "$LS_TEAM_ID" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -qF "\"$LS_SIGN_IDENTITY\""; then
    printf 'No valid "%s" in the keychain. See docs/reference.md.\n' "$LS_SIGN_IDENTITY" >&2
    exit 1
fi

version="$(plutil -extract CFBundleShortVersionString raw -o - "$root/Info.plist")"
tag="v$version"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf 'Info.plist version "%s" is not X.Y.Z.\n' "$version" >&2; exit 1; fi
if [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
    printf 'Not releasing: the clone has uncommitted changes, so the build would not match %s.\n' "$tag" >&2
    exit 1
fi
if [[ $upload == 1 && "$(git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}" || true)" != "$(git -C "$root" rev-parse HEAD)" ]]; then
    printf 'Not uploading: HEAD is not tagged %s. Tag the release commit first, or use --no-upload.\n' "$tag" >&2
    exit 1
fi

out="${LS_RELEASE_OUT:-$root/dist/release-out/$tag}"
rm -rf "$out"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
LS_SIGN_IDENTITY="$LS_SIGN_IDENTITY" LS_DIST_DIR="$work/build" "$root/scripts/build-app.sh"
app="$work/build/Lip Service.app"
zip="$out/Lip-Service-$version.zip"

# What the in-app updater holds every update to: Developer ID, this bundle id, this team. Keep it in step with
# SignedUpdate.requirement in DictationCore.
requirement="anchor apple generic and identifier \"$bundle_id\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$LS_TEAM_ID\""
codesign --verify --deep --strict -R "=$requirement" "$app"

ditto -c -k --norsrc --noextattr --keepParent "$app" "$work/notarize.zip"
notary=()
if [[ -n "$LS_NOTARY_PROFILE" ]]; then
    notary=(--keychain-profile "$LS_NOTARY_PROFILE")
else
    # %b: secret stores that keep one-line values hold the .p8's line breaks as literal \n.
    (umask 077; printf '%b\n' "$LS_NOTARY_KEY" > "$work/notary.p8")
    notary=(--key "$work/notary.p8" --key-id "$LS_NOTARY_KEY_ID" --issuer "$LS_NOTARY_ISSUER")
fi
printf 'Notarizing %s; Apple usually answers in a few minutes.\n' "$tag"
xcrun notarytool submit "$work/notarize.zip" "${notary[@]}" --wait --output-format json > "$work/notary.json" || true
status="$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
    submission="$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)"
    printf 'Notarization ended as "%s".\n' "${status:-unknown}" >&2
    [[ -n "$submission" ]] && xcrun notarytool log "$submission" "${notary[@]}" >&2 || true
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

ditto -c -k --norsrc --noextattr --keepParent "$app" "$zip"
# The zip the user gets, checked as the updater checks it: unpacked, Developer ID and team, accepted by Gatekeeper.
check="$work/check"
mkdir "$check"
ditto -x -k "$zip" "$check"
codesign --verify --deep --strict -R "=$requirement" "$check/Lip Service.app"
spctl --assess --type execute "$check/Lip Service.app"
printf 'Built %s\n' "$zip"
[[ $upload == 1 ]] || exit 0

if gh release view "$tag" --repo hunterbohm/lip-service >/dev/null 2>&1; then
    gh release upload "$tag" "$zip" --repo hunterbohm/lip-service --clobber
else
    gh release create "$tag" "$zip" --repo hunterbohm/lip-service --verify-tag --title "Lip Service $version" \
        --notes "Signed and notarized. Download Lip-Service-$version.zip, unzip it, and move Lip Service to Applications."
fi
printf 'Uploaded to the %s release; installed copies offer it within a day.\n' "$tag"
