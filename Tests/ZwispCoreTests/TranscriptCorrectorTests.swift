import Testing
import Foundation
@testable import ZwispCore

struct TranscriptCorrectorTests {
    // Default config: fuzzyMinLength 5, fuzzyTwoEditMinLength 8. Short names
    // (like "Dana") are deliberately fuzzy-ineligible under the defaults.
    private let defaults = Configuration.PersonalDictionary()

    // MARK: - Exact / casing

    @Test func casingFixRestoresRegisteredSpelling() {
        let result = TranscriptCorrector.correct("i love whisperkit", dictionary: ["WhisperKit"])
        #expect(result.text == "i love WhisperKit")
        #expect(result.corrections == [.init(original: "whisperkit", replacement: "WhisperKit")])
    }

    @Test func alreadyCorrectTextReturnsNoCorrections() {
        let result = TranscriptCorrector.correct("i love WhisperKit", dictionary: ["WhisperKit"])
        #expect(result.text == "i love WhisperKit")
        #expect(result.corrections.isEmpty)
    }

    // MARK: - Join

    @Test func joinFixMergesSplitWord() {
        let result = TranscriptCorrector.correct("try whisper kit today", dictionary: ["WhisperKit"])
        #expect(result.text == "try WhisperKit today")
        #expect(result.corrections == [.init(original: "whisper kit", replacement: "WhisperKit")])
    }

    // MARK: - Fuzzy

    @Test func fuzzyMatchFixesMisheardName() {
        // "Ziedo" is exactly fuzzyMinLength, so it is eligible under the
        // defaults — but only one edit away, which "zeedo" is. The string is
        // a spelling-distance fixture, not how the name sounds: the real
        // mishearing is "zeddo", which is two edits and covered below by
        // twoEditMishearingNeedsALoweredThreshold.
        let result = TranscriptCorrector.correct("call zeedo", dictionary: ["Ziedo"])
        #expect(result.text == "call Ziedo")
        #expect(result.corrections == [.init(original: "zeedo", replacement: "Ziedo")])
    }

    @Test func twoEditMishearingNeedsALoweredThreshold() {
        // "zeddo" is two edits from "Ziedo", and at 5 letters only one is
        // tolerated by default — exactly the tradeoff the config knob exposes.
        #expect(TranscriptCorrector.correct("call zeddo",
                                            dictionary: ["Ziedo"], config: defaults).text == "call zeddo")

        let config = Configuration.PersonalDictionary(fuzzyTwoEditMinLength: 5)
        let result = TranscriptCorrector.correct("call zeddo", dictionary: ["Ziedo"], config: config)
        #expect(result.text == "call Ziedo")
        #expect(result.corrections == [.init(original: "zeddo", replacement: "Ziedo")])
    }

    @Test func fuzzyMatchFixesMisheardMultiWordName() {
        // Normalized "ziedosolomon" is 12 chars, so 2 edits are tolerated and
        // even "zeddo solomon" is fixed under the *defaults*.
        let result = TranscriptCorrector.correct("email zeddo solomon",
                                                 dictionary: ["Ziedo Solomon"])
        #expect(result.text == "email Ziedo Solomon")
        #expect(result.corrections == [.init(original: "zeddo solomon", replacement: "Ziedo Solomon")])
    }

    // MARK: - Punctuation preservation

    @Test func punctuationSurvivesAroundReplacement() {
        let result = TranscriptCorrector.correct("ask zeedo.", dictionary: ["Ziedo"])
        #expect(result.text == "ask Ziedo.")
        #expect(result.corrections == [.init(original: "zeedo", replacement: "Ziedo")])
    }

    @Test func surroundingBracketsAndQuotesSurvive() {
        let result = TranscriptCorrector.correct("(whisperkit) is \"whisperkit\"",
                                                 dictionary: ["WhisperKit"])
        #expect(result.text == "(WhisperKit) is \"WhisperKit\"")
    }

    // MARK: - Negative / safety

    @Test func shortEntryDoesNotCaptureCommonWords() {
        // Under the defaults "Dana" is fuzzy-ineligible, so nearby everyday
        // words ("data", "dane") are left completely alone.
        let result = TranscriptCorrector.correct("the data came back",
                                                 dictionary: ["Dana"], config: defaults)
        #expect(result.text == "the data came back")
        #expect(result.corrections.isEmpty)
    }

    @Test func entriesBelowFuzzyMinLengthNeverFuzzyMatch() {
        // "Cat" normalizes to 3 chars, below fuzzyMinLength, so "car" is safe.
        let result = TranscriptCorrector.correct("my car is fast",
                                                 dictionary: ["Cat"], config: defaults)
        #expect(result.text == "my car is fast")
        #expect(result.corrections.isEmpty)
    }

    @Test func windowMatchingAnotherEntryIsNotFuzzyReplaced() {
        // "presto" is within one edit of "Preston" but is itself the exact
        // spelling of a different entry — it must never become "Preston".
        let result = TranscriptCorrector.correct("presto",
                                                 dictionary: ["Preston", "Presto"], config: defaults)
        #expect(result.text == "Presto")
        #expect(!result.text.contains("Preston"))
        #expect(result.corrections == [.init(original: "presto", replacement: "Presto")])
    }

    @Test func emptyDictionaryIsANoOp() {
        let result = TranscriptCorrector.correct("hello world", dictionary: [])
        #expect(result.text == "hello world")
        #expect(result.corrections.isEmpty)
    }

    @Test func emptyTextIsANoOp() {
        let result = TranscriptCorrector.correct("", dictionary: ["WhisperKit"])
        #expect(result.text.isEmpty)
        #expect(result.corrections.isEmpty)
    }

    // MARK: - Sounds-like aliases

    @Test func aliasFixesAMishearingTheFuzzyRulesCannot() {
        // "zeddo" → "ziedo" is two edits, and 5-letter entries only get one —
        // exactly the case a registered mishearing exists for. Punctuation
        // and surrounding text stay untouched.
        let entry = DictionaryEntry(word: "Ziedo", soundsLike: ["Zeddo"])
        let result = TranscriptCorrector.correct("call zeddo.", dictionary: [entry])
        #expect(result.text == "call Ziedo.")
        #expect(result.corrections == [.init(original: "zeddo", replacement: "Ziedo")])
    }

    @Test func aliasMatchesExactlyNeverFuzzily() {
        // Mishearings are often real words; a near-miss of one must not drift
        // into the name ("zedd" is one edit from the alias "zeddo").
        let entry = DictionaryEntry(word: "Ziedo", soundsLike: ["Zeddo"])
        let result = TranscriptCorrector.correct("zedd played", dictionary: [entry])
        #expect(result.text == "zedd played")
        #expect(result.corrections.isEmpty)
    }

    @Test func aliasBeatsAnotherEntrysFuzzyMatch() {
        // "zeddo" is one edit from the entry "Zeedo" but an exact registered
        // mishearing of "Ziedo" — the user's explicit mapping wins.
        let result = TranscriptCorrector.correct(
            "ping zeddo",
            dictionary: ["Zeedo", DictionaryEntry(word: "Ziedo", soundsLike: ["zeddo"])])
        #expect(result.text == "ping Ziedo")
    }

    @Test func aliasNeverRewritesAnotherEntrysExactSpelling() {
        // Colliding data passed straight to the corrector (the store refuses
        // to create it): a window spelling a real entry stays that entry.
        let result = TranscriptCorrector.correct(
            "ask zeddo",
            dictionary: ["Zeddo", DictionaryEntry(word: "Ziedo", soundsLike: ["zeddo"])])
        #expect(result.text == "ask Zeddo")
    }

    @Test func multiWordAndSplitAliasesMatch() {
        let zwisp = DictionaryEntry(word: "zwisp", soundsLike: ["the whisp"])
        #expect(TranscriptCorrector.correct("open the whisp now", dictionary: [zwisp]).text
                == "open zwisp now")

        // A one-word alias split across two transcript words gets the same
        // join tolerance the canonical spelling has.
        let ziedo = DictionaryEntry(word: "Ziedo", soundsLike: ["zeddo"])
        #expect(TranscriptCorrector.correct("call zed do, please", dictionary: [ziedo]).text
                == "call Ziedo, please")
    }

    @Test func shortAliasesMatchWithoutAnyLengthFloor() {
        // Exact alias matches don't need the fuzzy stage's length guards.
        let entry = DictionaryEntry(word: "Ziedo", soundsLike: ["zed"])
        #expect(TranscriptCorrector.correct("ask zed", dictionary: [entry]).text == "ask Ziedo")
    }

    // MARK: - Reporting

    @Test func correctionsListReportsOriginalAndReplacement() {
        let result = TranscriptCorrector.correct("using whisper kit and whisperkit",
                                                 dictionary: ["WhisperKit"])
        #expect(result.text == "using WhisperKit and WhisperKit")
        #expect(result.corrections == [
            .init(original: "whisper kit", replacement: "WhisperKit"),
            .init(original: "whisperkit", replacement: "WhisperKit"),
        ])
    }
}
