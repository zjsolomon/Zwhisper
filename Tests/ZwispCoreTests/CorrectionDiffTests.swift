import Testing
@testable import ZwispCore

struct CorrectionDiffTests {
    private let defaults = Configuration.PersonalDictionary()

    // MARK: - Substitutions

    @Test func singleWordSubstitutionIsExtracted() {
        let subs = CorrectionDiff.substitutions(
            from: "call zeddo tomorrow", to: "call Ziedo tomorrow", maxWords: 4)
        #expect(subs == [.init(original: "zeddo", replacement: "Ziedo")])
    }

    @Test func casingAndPunctuationChangesAreNotSubstitutions() {
        // Word forms are normalized before alignment, so "ziedo," vs "Ziedo"
        // matches — only genuinely different words make a block.
        let subs = CorrectionDiff.substitutions(
            from: "hi ziedo, ok", to: "Hi Ziedo. OK", maxWords: 4)
        #expect(subs.isEmpty)
    }

    @Test func pureInsertionsAndDeletionsAreIgnored() {
        #expect(CorrectionDiff.substitutions(
            from: "send the draft", to: "send the full draft now", maxWords: 4).isEmpty)
        #expect(CorrectionDiff.substitutions(
            from: "send the whole draft", to: "send the draft", maxWords: 4).isEmpty)
    }

    @Test func multiWordBlocksAreExtractedAndCapped() {
        let subs = CorrectionDiff.substitutions(
            from: "open the whisp now", to: "open zwisp now", maxWords: 4)
        #expect(subs == [.init(original: "the whisp", replacement: "zwisp")])

        // A wholesale rewrite (block longer than maxWords) is not a term.
        let rewrite = CorrectionDiff.substitutions(
            from: "a b c d e tail", to: "v w x y z tail", maxWords: 4)
        #expect(rewrite.isEmpty)
    }

    @Test func multipleSubstitutionsComeBackInOrder() {
        let subs = CorrectionDiff.substitutions(
            from: "zeddo pinged whisper git", to: "Ziedo pinged WhisperKit", maxWords: 4)
        #expect(subs == [
            .init(original: "zeddo", replacement: "Ziedo", atSentenceStart: true),
            .init(original: "whisper git", replacement: "WhisperKit"),
        ])
    }

    @Test func sentenceStartsAreMarked() {
        // Text start, and after ., !, ?, or a newline — but not mid-sentence.
        let subs = CorrectionDiff.substitutions(
            from: "Alpha one. Beta two\nGamma three, delta four",
            to: "Alphax one. Betax two\nGammax three, deltax four", maxWords: 4)
        #expect(subs.map { ($0.original, $0.atSentenceStart) }.elementsEqual(
            [("Alpha", true), ("Beta", true), ("Gamma", true), ("delta", false)],
            by: { $0.0 == $1.0 && $0.1 == $1.1 }))
    }

    // MARK: - Alias suggestions

    @Test func substitutionOntoADictionaryWordBecomesASuggestion() {
        let suggestions = CorrectionDiff.aliasSuggestions(
            injected: "call zeddo tomorrow", corrected: "call Ziedo tomorrow",
            dictionary: ["Ziedo"], config: defaults)
        #expect(suggestions == [.init(heard: "zeddo", word: "Ziedo")])
    }

    @Test func replacementsOffTheDictionaryAreNotSuggested() {
        // "colonel" → "kernel": a real fix, but zwisp has nowhere to put it
        // until "kernel" is a dictionary word.
        let suggestions = CorrectionDiff.aliasSuggestions(
            injected: "the colonel panicked", corrected: "the kernel panicked",
            dictionary: ["Ziedo"], config: defaults)
        #expect(suggestions.isEmpty)
    }

    @Test func suggestionsTheStoreWouldRefuseAreFiltered() {
        // Already registered on the target word; registered on another word;
        // spells another dictionary word outright.
        let dictionary: [DictionaryEntry] = [
            DictionaryEntry(word: "Ziedo", soundsLike: ["zeddo"]),
            DictionaryEntry(word: "Presto"),
        ]
        #expect(CorrectionDiff.aliasSuggestions(
            injected: "hi zeddo", corrected: "hi Ziedo",
            dictionary: dictionary, config: defaults).isEmpty)
        #expect(CorrectionDiff.aliasSuggestions(
            injected: "run presto", corrected: "run Ziedo",
            dictionary: dictionary, config: defaults).isEmpty)
    }

    @Test func spacingDriftOntoTheSameLettersIsNotAMishearing() {
        // "whisper kit" → "WhisperKit" is the corrector's split-join case;
        // registering it as an alias would just conflict with the word.
        let suggestions = CorrectionDiff.aliasSuggestions(
            injected: "try whisper kit", corrected: "try WhisperKit",
            dictionary: ["WhisperKit"], config: defaults)
        #expect(suggestions.isEmpty)
    }

    @Test func repeatedMishearingsSuggestOnlyOnce() {
        let suggestions = CorrectionDiff.aliasSuggestions(
            injected: "zeddo met zeddo", corrected: "Ziedo met Ziedo",
            dictionary: ["Ziedo"], config: defaults)
        #expect(suggestions == [.init(heard: "zeddo", word: "Ziedo")])
    }
}
