#!/bin/bash
# Vendors FluidAudio at a pinned commit into Vendor/FluidAudio and applies five patches. The first deletes the
# NemoTextProcessing binary target from the Swift 6.2+ manifest. The app never uses that text normalizer, and
# SwiftPM downloads binary targets with URLSession, which traps (exit 133) when run from an SSH session. The
# second builds the rescorer's character set once instead of on every word it compares, which was most of the
# rescoring time on long dictations. Its output is unchanged. The third adds VocabularyRescorer.create with a
# tokenizer that is already loaded, so the app reads tokenizer.json once, from the folder it checked, and a later
# vocabulary change reads no file. The existing create loads it from a directory and now calls the new one. The
# fourth keeps a word the decoder was sure of when a vocabulary term spelled differently would replace it, because
# the CTC comparison passes nearly every such swap. The fifth scores a heard word against a term by sound as well
# as spelling, so the commoner spelling of the same sounds counts as a near match. Safe to rerun.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag=v0.17.7
commit=503b4bd1bbf7220882de39fe8ae6716aae4132da
dest="$root/Vendor/FluidAudio"
patches=5
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
base = f"{package}/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/Rescorer"

def patch(path, edits):
    text = open(path).read()
    for old, new in edits:
        if text.count(old) != 1:
            sys.exit(f"{path}: expected one match for {old.strip().splitlines()[0][:70]!r}, found {text.count(old)}")
        text = text.replace(old, new)
    open(path, "w").write(text)

patch(f"{base}/VocabularyRescorer.swift", [
("""        public let endTime: Double
        let tokenRange: Range<Int>?
    }
""", """        public let endTime: Double
        let tokenRange: Range<Int>?
        /// The decoder's lowest token confidence in the word, punctuation aside. 1 when unknown.
        var confidence: Float = 1
    }
"""),
("""        var wordTokensAreContiguous = true

        for (tokenIndex, timing) in tokenTimings.enumerated() {""", """        var wordTokensAreContiguous = true
        var wordConfidence: Float = 1

        for (tokenIndex, timing) in tokenTimings.enumerated() {"""),
("""                            endTime: wordEnd,
                            tokenRange: wordTokensAreContiguous ? wordTokenStart..<wordTokenEnd : nil
                        ))
                }
                currentWord = ""
            }
""", """                            endTime: wordEnd,
                            tokenRange: wordTokensAreContiguous ? wordTokenStart..<wordTokenEnd : nil,
                            confidence: wordConfidence
                        ))
                }
                currentWord = ""
            }
"""),
("""                wordTokenStart = tokenIndex
                wordTokensAreContiguous = true
            } else {""", """                wordTokenStart = tokenIndex
                wordTokensAreContiguous = true
                wordConfidence = 1
            } else {"""),
("""            wordEnd = timing.endTime
            wordTokenEnd = tokenIndex + 1
""", """            if stripWordBoundaryPrefix(token).contains(where: { $0.isLetter || $0.isNumber }) {
                wordConfidence = min(wordConfidence, timing.confidence)
            }
            wordEnd = timing.endTime
            wordTokenEnd = tokenIndex + 1
"""),
("""                    endTime: wordEnd,
                    tokenRange: wordTokensAreContiguous ? wordTokenStart..<wordTokenEnd : nil
                ))
        }

        return wordTimings""", """                    endTime: wordEnd,
                    tokenRange: wordTokensAreContiguous ? wordTokenStart..<wordTokenEnd : nil,
                    confidence: wordConfidence
                ))
        }

        return wordTimings"""),
])

patch(f"{base}/VocabularyRescorer+TokenRescoring.swift", [
("""    // MARK: - CTC Match Types
""", """    /// A decoder at least this sure of every token in a span heard a real word, not a misheard name. The CTC
    /// comparison cannot overrule it, because its boost outweighs the acoustic difference between a common word
    /// and a name a letter or two away (`look` and `Loom`, `entry` and `Sentry`). Spans whose letters already
    /// spell the term, and differ only in spacing or case, are exempt.
    static let certainDecoderConfidence: Float = 0.95

    /// Whether the decoder was sure enough of the span that a term spelled differently must not replace it.
    func decoderWasCertain(of spanIndices: [Int], in wordTimings: [WordTiming], term: String) -> Bool {
        let letters = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        guard letters(spanIndices.map { wordTimings[$0].word }.joined()) != letters(term),
            spanIndices.allSatisfy({ wordTimings[$0].confidence >= Self.certainDecoderConfidence })
        else { return false }
        debugLog("    [CERTAIN] decoder was sure of '\\(spanIndices.map { wordTimings[$0].word }.joined(separator: " "))', keeping it over '\\(term)'")
        return true
    }

    // MARK: - CTC Match Types
"""),
("""                // Check if similarity meets threshold after all adjustments
                guard similarity >= minSimilarityForSpan else { continue }
""", """                // Check if similarity meets threshold after all adjustments
                guard similarity >= minSimilarityForSpan else { continue }
                if decoderWasCertain(of: spanIndices, in: wordTimings, term: vocabTerm) { continue }
"""),
("""                        if bestSimilarity < minSimilarityForSpan { continue }

                        // Get temporal window for the entire span""", """                        if bestSimilarity < minSimilarityForSpan { continue }
                        if decoderWasCertain(of: spanIndices, in: wordTimings, term: vocabTerm) {
                            continue
                        }

                        // Get temporal window for the entire span"""),
("""                    if bestSimilarity < minSimilarityForSpan { continue }

                    // Build the original phrase (single word or concatenated span)
                    let spanIndices = Array(wordIdx..<(wordIdx + matchedSpanLength))
""", """                    if bestSimilarity < minSimilarityForSpan { continue }

                    // Build the original phrase (single word or concatenated span)
                    let spanIndices = Array(wordIdx..<(wordIdx + matchedSpanLength))
                    if decoderWasCertain(of: spanIndices, in: wordTimings, term: vocabTerm) {
                        continue
                    }
"""),
("""                continue
            }

            let firstIdx = span.first!
            let lastIdx = span.last!""", """                continue
            }
            if decoderWasCertain(of: span, in: wordTimings, term: vocabTerm) { continue }

            let firstIdx = span.first!
            let lastIdx = span.last!"""),
])
base = f"{package}/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/Rescorer"

def patch(path, edits):
    text = open(path).read()
    for old, new, count in edits:
        if text.count(old) != count:
            sys.exit(f"{path}: expected {count} matches for {old.strip().splitlines()[0][:70]!r}, found {text.count(old)}")
        text = text.replace(old, new)
    open(path, "w").write(text)

patch(f"{base}/VocabularyRescorer+Utilities.swift", [
("""    /// Compute string similarity with length penalty for compound matches.""", """    /// The better of the spelling similarity and the similarity of the two sound keys, so a term the decoder wrote
    /// with the commoner spelling of the same sounds (`in physical` for `Infisical`) scores as the near match it is.
    static func soundAwareSimilarity(_ a: String, _ b: String) -> Float {
        max(stringSimilarity(a, b), stringSimilarity(soundKey(a), soundKey(b)))
    }

    /// The letters and digits of `text` with English spellings of one sound merged: ph and f, ck and c and q as k,
    /// c before e, i or y and z as s, x as ks, y after the first letter as i, and a doubled sound once.
    static func soundKey(_ text: String) -> String {
        let letters = Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
        var key: [Character] = []
        var index = 0
        while index < letters.count {
            let letter = letters[index]
            let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
            let sounds: [Character]
            switch letter {
            case "p" where next == "h", "c" where next == "k":
                sounds = [letter == "p" ? "f" : "k"]
                index += 1
            case "c": sounds = [next.map { "eiy".contains($0) } == true ? "s" : "k"]
            case "q": sounds = ["k"]
            case "x": sounds = ["k", "s"]
            case "z": sounds = ["s"]
            case "y" where !key.isEmpty: sounds = ["i"]
            default: sounds = [letter]
            }
            for sound in sounds where key.last != sound { key.append(sound) }
            index += 1
        }
        return String(key)
    }

    /// Compute string similarity with length penalty for compound matches.""", 1),
])

patch(f"{base}/VocabularyRescorer+TokenRescoring.swift", [
("""                            let similarity = Self.stringSimilarity(normalizedPhrase, form.normalized)""",
 """                            let similarity = Self.soundAwareSimilarity(normalizedPhrase, form.normalized)""", 1),
("""                        let similarity = Self.stringSimilarity(normalizedWord, form.normalized)""",
 """                        let similarity = Self.soundAwareSimilarity(normalizedWord, form.normalized)""", 1),
("""                                let concatSimilarity = Self.stringSimilarity(concatenated, form.normalized)""",
 """                                let concatSimilarity = Self.soundAwareSimilarity(concatenated, form.normalized)""", 2),
])
PATCH

rm -rf "$dest"
mv "$staging/FluidAudio" "$dest"
touch "$stamp"
printf 'Vendored FluidAudio %s (%s).\n' "$tag" "$commit"
