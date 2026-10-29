import DictationCore
import FluidAudio

/// What `VocabularyBoostingSession` does with untokenized terms, with a tokenizer the caller already holds, so no
/// file is read. A term that encodes to nothing is dropped.
func tokenizedVocabulary(_ vocabulary: Vocabulary, using tokenizer: CtcTokenizer) -> CustomVocabularyContext {
    let terms = vocabulary.terms.compactMap { term -> CustomVocabularyTerm? in
        let ids = tokenizer.encode(term.text)
        return ids.isEmpty ? nil : CustomVocabularyTerm(text: term.text, ctcTokenIds: ids)
    }
    return CustomVocabularyContext(terms: terms, minSimilarity: Float(vocabulary.minSimilarity))
}
