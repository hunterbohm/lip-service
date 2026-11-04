import Foundation
import Testing
@testable import DictationCore

/// The tokenizer needs RoBERTa's word list, which ships with the formatter model rather than the repo, so those
/// checks run only where the formatter folder is installed. FORMATTER_DIR points at another copy.
private let formatterFolder: URL? = {
    let path = ProcessInfo.processInfo.environment["FORMATTER_DIR"]
        ?? (NSHomeDirectory() + "/Library/Application Support/Dictation/Formatter")
    let url = URL(fileURLWithPath: path)
    return FileManager.default.fileExists(atPath: url.appending(path: "vocab.json").path) ? url : nil
}()

private let installed: (bpe: ByteLevelBPE, config: FormatterConfig)? = {
    guard let folder = formatterFolder,
          let vocabData = try? Data(contentsOf: folder.appending(path: "vocab.json")),
          let vocab = try? JSONDecoder().decode([String: Int].self, from: vocabData),
          let merges = try? String(contentsOf: folder.appending(path: "merges.txt"), encoding: .utf8),
          let configData = try? Data(contentsOf: folder.appending(path: "formatter.json")),
          let config = try? JSONDecoder().decode(FormatterConfig.self, from: configData) else { return nil }
    return (ByteLevelBPE(vocab: vocab, merges: merges.split(separator: "\n").map(String.init)), config)
}()

private let cut = FormatterConfig.Cut(brk: 0.7, item: 0.25, quote: 0.7, drop: 0.5, minWordsForBreaks: 60)

private func scores(_ flat: [Double]) -> WordScores {
    WordScores(brk: Array(flat[0..<3]), item: Array(flat[3..<6]), qo: Array(flat[6..<8]), qc: Array(flat[8..<10]),
               drop: Array(flat[10..<12]), punct: Array(flat[12..<19]), cap: Array(flat[19..<21]))
}

@Suite("Smart formatting") struct FormatterTests {
    @Test("decide and render match the training code", arguments: layoutFixtures.indices)
    func layoutParity(_ i: Int) {
        let fixture = layoutFixtures[i]
        let labels = SmartLayout.decide(words: fixture.words, scores: fixture.scores.map(scores), cut: cut)
        #expect(SmartLayout.render(words: fixture.words, labels: labels) == fixture.expected)
    }

    @Test("pauses match the training code", arguments: pauseFixtures.indices)
    func pauseParity(_ i: Int) {
        let fixture = pauseFixtures[i]
        let tokens = fixture.tokens.map { TimedToken(text: $0.0, start: $0.1, end: $0.2) }
        let got = WordPauses.before(text: fixture.text, raw: fixture.raw, tokens: tokens)
        #expect(got?.count == fixture.expected?.count)
        if let got, let expected = fixture.expected {
            for (a, b) in zip(got, expected) { #expect(abs(a - b) < 1e-6) }
        }
    }

    @Test("the tokenizer matches RoBERTa's", .enabled(if: installed != nil))
    func bpeParity() throws {
        let bpe = try #require(installed).bpe
        for fixture in bpeFixtures { #expect(bpe.ids(word: fixture.word) == fixture.ids, "\(fixture.word)") }
    }

    @Test("model input matches training's, with app and pause tokens", .enabled(if: installed != nil))
    func encodeParity() throws {
        let (bpe, config) = try #require(installed)
        let encoder = LayoutEncoder(bpe: bpe, config: config)
        for fixture in encodeFixtures {
            let windows = encoder.windows(words: fixture.words, app: fixture.app.flatMap(ProfileGroup.init(rawValue:)),
                                          gaps: fixture.gaps)
            #expect(windows.count == 1)
            let used = windows[0].mask.filter { $0 == 1 }.count
            #expect(windows[0].ids.prefix(used).map(Int.init) == fixture.ids)
            #expect(windows[0].ids.count == config.maxTokens)
        }
    }

    @Test("a long dictation is cut into windows that each fit and cover every word once", .enabled(if: installed != nil))
    func windows() throws {
        let (bpe, config) = try #require(installed)
        let words = (0..<400).map { "word\($0)." }
        let windows = LayoutEncoder(bpe: bpe, config: config).windows(words: words, app: .aiAndCode, gaps: nil)
        #expect(windows.count > 1)
        #expect(windows.allSatisfy { $0.ids.count == config.maxTokens && $0.mask.filter { $0 == 1 }.count <= config.maxTokens })
        #expect(windows.flatMap { $0.wordAt.compactMap { $0 } } == Array(words.indices))
    }

    @Test("quotes come in pairs, and a one-item list is no list")
    func guards() {
        let words = ["He", "said", "no", "way.", "First,", "call", "Sam."]
        var flat = [[Double]](repeating: [1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0], count: words.count)
        flat[2][6] = 0; flat[2][7] = 1
        flat[5][3] = 0; flat[5][4] = 1
        let labels = SmartLayout.decide(words: words, scores: flat.map(scores), cut: cut)
        #expect(!labels[2].quoteOpens)
        #expect(labels[5].item == 0)
        #expect(SmartLayout.render(words: words, labels: labels) == "He said no way first call Sam")
    }

    private func plain(_ count: Int) -> [[Double]] {
        [[Double]](repeating: [1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0], count: count)
    }

    @Test("the count before a list item goes, and a number ending the previous item stays")
    func countingStaysInItsItem() {
        let words = ["First,", "order", "two.", "Second,", "call", "Sam."]
        var flat = plain(words.count)
        for i in [1, 4] { flat[i][3] = 0; flat[i][4] = 1 }
        let labels = SmartLayout.decide(words: words, scores: flat.map(scores), cut: cut)
        #expect(SmartLayout.render(words: words, labels: labels) == "1. Order two\n2. Call Sam")
        let ended = ["Order", "two.", "Call", "Sam."]
        var endedScores = plain(ended.count)
        for i in [0, 2] { endedScores[i][3] = 0; endedScores[i][4] = 1 }
        let endedLabels = SmartLayout.decide(words: ended, scores: endedScores.map(scores), cut: cut)
        #expect(SmartLayout.render(words: ended, labels: endedLabels) == "1. Order two\n2. Call Sam")
    }

    @Test("a drop score alone never removes a word that is not a spoken command")
    func onlyCommandsDrop() {
        let words = ["Do", "not", "send", "it", "new", "line", "today."]
        var flat = plain(words.count)
        for i in [1, 4, 5] { flat[i][10] = 0; flat[i][11] = 1 }
        let labels = SmartLayout.decide(words: words, scores: flat.map(scores), cut: cut)
        #expect(SmartLayout.render(words: words, labels: labels) == "Do not send it today")
    }

    @Test("a quote on a dropped word leaves no stray quote mark")
    func quotesOnDroppedWords() {
        let words = ["He", "said", "hello", "end", "quote"]
        var flat = plain(words.count)
        flat[1][6] = 0; flat[1][7] = 1
        flat[2][8] = 0; flat[2][9] = 1
        flat[3][8] = 0; flat[3][9] = 1
        for i in [3, 4] { flat[i][10] = 0; flat[i][11] = 1 }
        let labels = SmartLayout.decide(words: words, scores: flat.map(scores), cut: cut)
        let text = SmartLayout.render(words: words, labels: labels)
        #expect(text.filter { $0 == "\"" }.count % 2 == 0)
        #expect(text == "He \"said hello\"")
    }

    @Test("formatting only drops words, never adds or changes them", arguments: layoutFixtures.indices)
    func keepsWords(_ i: Int) {
        let fixture = layoutFixtures[i]
        let labels = SmartLayout.decide(words: fixture.words, scores: fixture.scores.map(scores), cut: cut)
        let kept = zip(fixture.words, labels).filter { !$0.1.drop }.map { SmartLayout.key(SmartLayout.split($0.0).core) }
        let out = SmartLayout.render(words: fixture.words, labels: labels).split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { $0 != "-" && !($0.hasSuffix(".") && Int($0.dropLast()) != nil) }
            .map { SmartLayout.key(SmartLayout.split($0).core) }
        #expect(out == kept)
    }
}
