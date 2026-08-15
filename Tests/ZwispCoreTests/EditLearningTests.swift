import Testing
@testable import ZwispCore

struct EditLearningTests {
    private let defaults = Configuration.PersonalDictionary()

    // MARK: - editedText (re-anchoring the injected span)

    @Test func fixInsideTheSpanIsSeen() {
        // A document with text around the injection; the user fixes one word
        // inside the injected sentence.
        let injected = "call zeddo about the invoice"
        let baseline = "Notes:\n" + injected + "\nRegards"
        let current = "Notes:\ncall Ziedo about the invoice\nRegards"
        #expect(EditLearning.editedText(baseline: baseline, injected: injected,
                                        current: current, contextChars: 120)
                == "call Ziedo about the invoice")
    }

    @Test func editsOutsideTheSpanDoNotShiftIt() {
        // Typing elsewhere in the field must not read as a fix of our text.
        let injected = "send the report"
        let baseline = "TODO: " + injected + " today"
        let current = "TODO (urgent!): " + injected + " today"
        // The prefix anchor changed, so the span can't be located — that's the
        // safe answer, not a phantom edit.
        #expect(EditLearning.editedText(baseline: baseline, injected: injected,
                                        current: current, contextChars: 120) == nil)
    }

    @Test func fieldThatIsExactlyTheInjectionAnchorsAtBothEnds() {
        #expect(EditLearning.editedText(baseline: "hi zeddo", injected: "hi zeddo",
                                        current: "hi Ziedo", contextChars: 120)
                == "hi Ziedo")
    }

    @Test func untouchedSpanReadsBackVerbatim() {
        let injected = "nothing changed here"
        let baseline = "A. " + injected + " B."
        #expect(EditLearning.editedText(baseline: baseline, injected: injected,
                                        current: baseline, contextChars: 10)
                == injected)
    }

    @Test func smartQuoteBeautificationDoesNotHideTheSpan() {
        // The Notes regression: zwisp injects a straight apostrophe, Notes
        // displays a curly one — matching must still anchor and see the fix.
        let injected = "my brother's name is Riyad"
        let baseline = "Note:\nmy brother\u{2019}s name is Riyad"
        let current = "Note:\nmy brother\u{2019}s name is Riyadh"
        #expect(EditLearning.editedText(baseline: baseline, injected: injected,
                                        current: current, contextChars: 120)
                == "my brother's name is Riyadh")
    }

    @Test func canonicalizeFoldsTypographicVariants() {
        #expect(EditLearning.canonicalize("\u{201C}I\u{2019}ll\u{201D} \u{2014} fine\u{2026}")
                == "\"I'll\" - fine...")
    }

    @Test func injectedTextMissingFromBaselineIsNil() {
        #expect(EditLearning.editedText(baseline: "something else entirely",
                                        injected: "call zeddo",
                                        current: "call Ziedo", contextChars: 120) == nil)
    }

    @Test func removedSuffixAnchorGivesUp() {
        let injected = "middle part"
        let baseline = "start " + injected + " finish"
        // The user deleted everything after our span, anchor and all.
        #expect(EditLearning.editedText(baseline: baseline, injected: injected,
                                        current: "start middle part", contextChars: 6) == nil)
    }

    // MARK: - actions (what a fix teaches)

    @Test func fixOntoADictionaryWordBecomesAMishearing() {
        let actions = EditLearning.actions(
            injected: "call zeddo now", edited: "call Ziedo now",
            dictionary: ["Ziedo"], config: defaults,
            isKnownWord: { _ in true })
        #expect(actions == [.addMishearing(heard: "zeddo", word: "Ziedo")])
    }

    @Test func fixOntoAnUnknownWordAddsWordPlusMishearing() {
        let actions = EditLearning.actions(
            injected: "we use whisper git daily", edited: "we use WhisperKit daily",
            dictionary: ["Ziedo"], config: defaults,
            isKnownWord: { !["WhisperKit"].contains($0) })
        #expect(actions == [.addWord(word: "WhisperKit", heard: "whisper git")])
    }

    @Test func ordinaryContentEditsLearnNothing() {
        // "big" → "huge" is a choice, not a mishearing: every replacement word
        // is ordinary vocabulary.
        let actions = EditLearning.actions(
            injected: "a big win", edited: "a huge win",
            dictionary: ["Ziedo"], config: defaults,
            isKnownWord: { _ in true })
        #expect(actions.isEmpty)
    }

    @Test func mishearingOfExistingWordIsNotAlsoANewWord() {
        // Both passes see the same substitution; only the mishearing lands.
        let actions = EditLearning.actions(
            injected: "ping zeddo", edited: "ping Ziedo",
            dictionary: ["Ziedo"], config: defaults,
            isKnownWord: { _ in false })
        #expect(actions == [.addMishearing(heard: "zeddo", word: "Ziedo")])
    }

    @Test func heardFormsThatSpellDictionaryContentAreNotLearned() {
        // Rewriting an existing entry ("Presto") into some new word must not
        // register "presto" as that word's mishearing.
        let actions = EditLearning.actions(
            injected: "run presto", edited: "run Kubeflow",
            dictionary: ["Presto"], config: defaults,
            isKnownWord: { _ in false })
        #expect(actions.isEmpty)
    }

    @Test func properNounRespellingIsLearnedEvenWhenSpellCheckerKnowsIt() {
        // The Riyadh regression: the fixed name is in the system dictionary,
        // but a capitalized, nearly-identical respelling is still a name fix.
        let actions = EditLearning.actions(
            injected: "my brother's name is Riyad.", edited: "my brother's name is Riyadh.",
            dictionary: ["Ziedo"], config: defaults,
            isKnownWord: { _ in true })   // spell checker knows everything
        #expect(actions == [.addWord(word: "Riyadh", heard: "Riyad")])
    }

    @Test func knownWordFixesWithoutProperNounShapeStayUnlearned() {
        // Lowercase → not a name ("there" → "their" must NEVER become an
        // exact-match alias), dissimilar → a content edit, sentence start →
        // capitalization is grammar.
        let cases: [(String, String)] = [
            ("we went there today", "we went their today"),
            ("a Big win for us", "a Huge win for us"),
            ("Their turn came. Their turn went.", "There turn came. There turn went."),
        ]
        for (injected, edited) in cases {
            #expect(EditLearning.actions(
                injected: injected, edited: edited,
                dictionary: ["Ziedo"], config: defaults,
                isKnownWord: { _ in true }).isEmpty,
                "expected nothing learned for \(injected) → \(edited)")
        }
    }

    @Test func repeatedFixesDeduplicate() {
        let actions = EditLearning.actions(
            injected: "zeddo and zeddo", edited: "Zorbo and Zorbo",
            dictionary: [], config: defaults,
            isKnownWord: { _ in false })
        #expect(actions == [.addWord(word: "Zorbo", heard: "zeddo")])
    }
}
