#!/bin/bash
# Vendors FluidAudio at a pinned commit into Vendor/FluidAudio and applies three patches. The first deletes the
# NemoTextProcessing binary target from the Swift 6.2+ manifest. The app never uses that text normalizer, and
# SwiftPM downloads binary targets with URLSession, which traps (exit 133) when run from an SSH session. The
# second builds the rescorer's character set once instead of on every word it compares, which was most of the
# rescoring time on long dictations. Its output is unchanged. The third adds VocabularyRescorer.create with a
# tokenizer that is already loaded, so the app reads tokenizer.json once, from the folder it checked, and a later
# vocabulary change reads no file. The existing create loads it from a directory and now calls the new one. Safe
# to rerun.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag=v0.17.7
commit=503b4bd1bbf7220882de39fe8ae6716aae4132da
dest="$root/Vendor/FluidAudio"
patches=3
stamp="$dest/.vendored-$commit-patches-$patches"
[[ -f "$stamp" ]] && exit 0

mkdir -p "$root/Vendor"
staging="$(mktemp -d "$root/Vendor/.fetch.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/FluidInference/FluidAudio.git "$staging/FluidAudio" 2>&1 \
    | grep -v 'is not a commit' >&2 || true
actual="$(git -C "$staging/FluidAudio" rev-parse HEAD)"
if [[ "$actual" != "$commit" ]]; then
    printf 'FluidAudio %s resolved to %s, expected %s.\n' "$tag" "$actual" "$commit" >&2
    exit 1
fi
rm -rf "$staging/FluidAudio/.git"

python3 -I - "$staging/FluidAudio" <<'PATCH'
import re, sys
package = sys.argv[1]
path = f"{package}/Package@swift-6.2.swift"
text = open(path).read()
patterns = [
    r'\n\s*// The prebuilt xcframework has no visionOS slice\.\n\s*\.target\(\s*name: "NemoTextProcessing",\s*condition: [^\n]*\n\s*\),',
    r'\n\s*// Byte-exact NeMo text normalization[^\n]*\n(?:\s*//[^\n]*\n)*\s*\.binaryTarget\(\s*name: "NemoTextProcessing",\s*url:\s*"[^"]+",\s*checksum: "[0-9a-f]+"\s*\),',
]
for pattern in patterns:
    text, n = re.subn(pattern, "", text)
    if n != 1:
        sys.exit(f"{path}: expected one match for {pattern[:70]!r}, found {n}")
if "NemoTextProcessing.xcframework" in text:
    sys.exit(f"{path}: the binary target is still referenced")
open(path, "w").write(text)

path = f"{package}/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/Rescorer/VocabularyRescorer+Utilities.swift"
text = open(path).read()
old = """    static func normalizeForSimilarity(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))
"""
new = """    private static let similarityCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))

    static func normalizeForSimilarity(_ text: String) -> String {
        let allowed = similarityCharacters
"""
if text.count(old) != 1:
    sys.exit(f"{path}: expected one normalizeForSimilarity to patch, found {text.count(old)}")
open(path, "w").write(text.replace(old, new))

path = f"{package}/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/Rescorer/VocabularyRescorer.swift"
text = open(path).read()
old = """
        let useBKTree = ContextBiasingConstants.useBkTree
"""
new = """
        return create(spotter: spotter, vocabulary: vocabulary, config: config, ctcTokenizer: tokenizer)
    }

    /// Create rescorer with a tokenizer that is already loaded, so nothing is read from disk.
    public static func create(
        spotter: CtcKeywordSpotter,
        vocabulary: CustomVocabularyContext,
        config: Config = .default,
        ctcTokenizer tokenizer: CtcTokenizer
    ) -> VocabularyRescorer {
        let useBKTree = ContextBiasingConstants.useBkTree
"""
if text.count(old) != 1:
    sys.exit(f"{path}: expected one useBKTree line to patch, found {text.count(old)}")
open(path, "w").write(text.replace(old, new))
PATCH

rm -rf "$dest"
mv "$staging/FluidAudio" "$dest"
touch "$stamp"
printf 'Vendored FluidAudio %s (%s).\n' "$tag" "$commit"
