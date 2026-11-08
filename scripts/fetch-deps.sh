#!/bin/bash
# Vendors FluidAudio at a pinned commit into Vendor/FluidAudio and applies six patches. The first deletes the
# NemoTextProcessing binary target from the Swift 6.2+ manifest. The app never uses that text normalizer, and
# SwiftPM downloads binary targets with URLSession, which traps (exit 133) when run from an SSH session. The
# NemoTextProcessing trait stays off, so the text-to-speech frontends pass text through, and Package.swift turns on
# only the TTS trait, for the Phonon voices. The second builds the rescorer's character set once instead of on every
# word it compares, which was most of the rescoring time on long dictations. Its output is unchanged. v0.18.3
# precomputes more per request but still calls normalizeForSimilarity per word, so the patch still pays. The third
# adds VocabularyRescorer.create with a tokenizer that is already loaded, so the app reads tokenizer.json once, from
# the folder it checked, and a later vocabulary change reads no file. The existing create loads it from a directory
# and now calls the new one. The fourth keeps a word the decoder was sure of when a vocabulary term spelled
# differently would replace it, because the CTC comparison passes nearly every such swap. v0.18.3 has a gate of its
# own (confidentWordBiasGate, issue #967): a span heard at 0.99 or more loses the context bias, except a close
# spelling of the term, which keeps it. On Lip Service's test, `entry` still became `Sentry`, which is a close
# spelling, in 3 of 10 sentences that v0.17.7 with this patch left alone, so the patch is kept and moved to where
# v0.18.3 decides a replacement, using the decoder confidence v0.18.3 now records for each word, counted over the tokens that hold a letter or digit so an unsure trailing comma does not weaken it. It vetoes at 0.95,
# close spellings included, and exempts a span whose letters already spell the term. The fifth scores a heard word
# against a term by sound as well as spelling, so the commoner spelling of the same sounds counts as a near match.
# v0.18.3 has nothing like it. The sixth stops a model download from writing where a server says.
# ModelHub.allowedFiles, set by the app, names the files it reads in each repository, and the download fetches only
# those. Whatever it fetches goes through DownloadGuard, which refuses a path that is absolute, has an empty, . or
# .. component, or lands outside the model folder, before anything is written. The download also stops using a
# token or a registry address from the environment, so a request goes to huggingface.co with no credentials.
# v0.18.3 changed ModelHub only in what it purges and how it judges a cache, not where it writes, so the sixth patch
# is unchanged. Safe to rerun, and a change to this script or the guard re-vendors on the next run.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag=v0.18.3
commit=c8b41f98eae668794dd0083bbe028fe7e6585051
dest="$root/Vendor/FluidAudio"
# The stamp holds a hash of this script and the guard, so changing a patch re-vendors, not only a new commit.
digest="$(cat "$0" "$root/scripts/download-guard/DownloadGuard.swift" | shasum -a 256 | cut -c1-12)"
stamp="$dest/.vendored-$commit-$digest"
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

python3 -I - "$staging/FluidAudio" "$root/scripts/download-guard/DownloadGuard.swift" <<'PATCH'
import re, shutil, sys
package, guard = sys.argv[1], sys.argv[2]
path = f"{package}/Package@swift-6.2.swift"
text = open(path).read()
patterns = [
    r'\n\s*// The prebuilt xcframework has no visionOS or tvOS slice\.\n\s*\.target\(\s*name: "NemoTextProcessing",\s*condition: [^\n]*\n\s*\),',
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

base = f"{package}/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/Rescorer"

def patch(path, edits):
    text = open(path).read()
    for old, new, count in edits:
        if text.count(old) != count:
            sys.exit(f"{path}: expected {count} matches for {old.strip().splitlines()[0][:70]!r}, found {text.count(old)}")
        text = text.replace(old, new)
    open(path, "w").write(text)

patch(f"{base}/VocabularyRescorer.swift", [
("""        var minConfidence: Float? = nil
    }
""", """        var minConfidence: Float? = nil
        /// The lowest token confidence in the word, punctuation aside; nil when the timings carry none. A trailing
        /// comma or period the decoder is unsure of must not make a confidently heard word look uncertain.
        var letterConfidence: Float? = nil
    }
""", 1),
("""        var wordMinConfidence = Float.infinity

""", """        var wordMinConfidence = Float.infinity
        var wordLetterConfidence = Float.infinity

""", 1),
("""                            minConfidence: wordMinConfidence.isFinite ? wordMinConfidence : nil
                        ))""", """                            minConfidence: wordMinConfidence.isFinite ? wordMinConfidence : nil,
                            letterConfidence: wordLetterConfidence.isFinite ? wordLetterConfidence : nil
                        ))""", 1),
("""                wordMinConfidence = .infinity
            } else {""", """                wordMinConfidence = .infinity
                wordLetterConfidence = .infinity
            } else {""", 1),
("""            wordMinConfidence = min(wordMinConfidence, timing.confidence)
""", """            wordMinConfidence = min(wordMinConfidence, timing.confidence)
            if stripWordBoundaryPrefix(token).contains(where: { $0.isLetter || $0.isNumber }) {
                wordLetterConfidence = min(wordLetterConfidence, timing.confidence)
            }
""", 1),
("""                    minConfidence: wordMinConfidence.isFinite ? wordMinConfidence : nil
                ))""", """                    minConfidence: wordMinConfidence.isFinite ? wordMinConfidence : nil,
                    letterConfidence: wordLetterConfidence.isFinite ? wordLetterConfidence : nil
                ))""", 1),
])

patch(f"{base}/VocabularyRescorer+TokenEvaluation.swift", [
("""    /// Whether the TDT decoder heard every word of the candidate's span with at least""", """    /// A decoder at least this sure of every token in a span heard a real word, not a misheard name. The CTC
    /// comparison cannot overrule it, because its boost outweighs the acoustic difference between a common word
    /// and a name a letter or two away (`look` and `Loom`, `entry` and `Sentry`). Upstream's own gate lets a close
    /// spelling keep its bias, which swaps `entry` for `Sentry`, so this one also covers close spellings. A span
    /// whose letters already spell the term, and differ only in spacing or case, is exempt.
    static let certainDecoderConfidence: Float = 0.95

    /// Whether the decoder was sure enough of the candidate's span that a term spelled differently must not replace it.
    static func decoderWasCertain(of candidate: CTCMatchCandidate, wordTimings: [WordTiming]) -> Bool {
        let letters = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        guard !candidate.spanIndices.isEmpty,
            letters(candidate.originalPhrase) != letters(candidate.vocabTerm),
            candidate.spanIndices.allSatisfy({ index in
                guard wordTimings.indices.contains(index), let confidence = wordTimings[index].letterConfidence else {
                    return false
                }
                return confidence >= certainDecoderConfidence
            })
        else { return false }
        return true
    }

    /// Whether the TDT decoder heard every word of the candidate's span with at least""", 1),
("""        let shouldReplace = boostedVocabScore > originalCtcScore
""", """        let shouldReplace = boostedVocabScore > originalCtcScore && !Self.decoderWasCertain(of: candidate, wordTimings: wordTimings)
""", 1),
])

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

download = f"{package}/Sources/FluidAudio/Shared/Download"
shutil.copyfile(guard, f"{download}/DownloadGuard.swift")

patch(f"{download}/ModelHub.swift", [
("""    public static var offlineMode: Bool {
        get { HFClient.offlineMode }
        set { HFClient.offlineMode = newValue }
    }
""", """    public static var offlineMode: Bool {
        get { HFClient.offlineMode }
        set { HFClient.offlineMode = newValue }
    }

    /// The files a download may fetch, relative to the model folder, by upstream repository path like
    /// `ModelRegistry.revisionOverrides`. A repository with an entry fetches nothing else, whatever the server lists.
    nonisolated(unsafe) public static var allowedFiles: [String: Set<String>] = [:]
""", 1),
("""            includeRepoRootFiles: true, fetch: treeFetch)
        try ModelCache.adoptLegacyCache(
""", """            includeRepoRootFiles: true, fetch: treeFetch)
        filesToDownload = try DownloadGuard.vet(
            filesToDownload, allowed: allowedFiles[repo.remotePath], under: repoPath
        ) { ModelCache.localPath(for: $0.path, subPath: subPath) }
        try ModelCache.adoptLegacyCache(
""", 1),
("""            let destPath = repoPath.appendingPathComponent(localPath)
""", """            let destPath = try DownloadGuard.destination(of: localPath, under: repoPath)
""", 1),
("""            includeRepoRootFiles: false, fetch: HFTreeLister.fetch(using: listingSession))
        try ModelCache.adoptLegacyCache(
""", """            includeRepoRootFiles: false, fetch: HFTreeLister.fetch(using: listingSession))
        filesToDownload = try DownloadGuard.vet(
            filesToDownload, allowed: allowedFiles[repo.remotePath], under: repoDirectory
        ) { $0.path }
        try ModelCache.adoptLegacyCache(
""", 1),
("""        let destPath = repoDirectory.appendingPathComponent(file.path)
""", """        let destPath = try DownloadGuard.destination(of: file.path, under: repoDirectory)
""", 1),
])

patch(f"{download}/HFClient.swift", [
("""    /// HuggingFace token from the environment, if available. Supports the env
    /// vars used by the official CLI (`HF_TOKEN`), the Python `huggingface_hub`
    /// library (`HUGGING_FACE_HUB_TOKEN`), and LangChain/older integrations
    /// (`HUGGINGFACEHUB_API_TOKEN`).
    static var huggingFaceToken: String? {
        ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
    }
""", """    /// Always nil. The models are public, and a token from the environment would go to any host a listing points at.
    static var huggingFaceToken: String? { nil }
""", 1),
])

patch(f"{package}/Sources/FluidAudio/ModelRegistry.swift", [
("""    /// Priority: programmatic override → REGISTRY_URL env var → MODEL_REGISTRY_URL env var → default
    public static var baseURL: String {
        get {
            _customBaseURL
                ?? ProcessInfo.processInfo.environment["REGISTRY_URL"]
                ?? ProcessInfo.processInfo.environment["MODEL_REGISTRY_URL"]
                ?? "https://huggingface.co"
        }
""", """    /// The REGISTRY_URL environment variables are not read, so the environment cannot send a download elsewhere.
    public static var baseURL: String {
        get {
            _customBaseURL ?? "https://huggingface.co"
        }
""", 1),
])
PATCH

rm -rf "$dest"
mv "$staging/FluidAudio" "$dest"
touch "$stamp"
printf 'Vendored FluidAudio %s (%s).\n' "$tag" "$commit"
