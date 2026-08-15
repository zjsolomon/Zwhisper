import Foundation

/// The pure half of passive edit learning ("fix a word in place and zwisp
/// learns it", Wispr-style). The app layer watches the focused field's text
/// after an injection; this type answers the two questions that watching
/// raises, deterministically and unit-tested:
///
/// 1. `editedText` — given the field's baseline value and its value now,
///    what does the injected span look like at this moment? (Re-anchored by
///    the unchanged context around it, so edits elsewhere in the field don't
///    produce phantom corrections.)
/// 2. `actions` — given the injected text and its edited form, what should
///    zwisp learn? Substitutions that land on a dictionary word become
///    mishearings; substitutions onto an *unknown* word (not ordinary
///    vocabulary — the injected `isKnownWord` check) become new dictionary
///    words with the heard form attached. Ordinary rewrites learn nothing.
///
/// Every action is later confirmed by a cancellable countdown toast, so the
/// gates here aim for "rarely wrong", not "never fires".
public enum EditLearning {
    /// Something worth learning from one in-place fix.
    public enum Action: Equatable {
        /// The user fixed `heard` into the existing dictionary word `word`.
        case addMishearing(heard: String, word: String)
        /// The user fixed `heard` into `word`, which zwisp doesn't know yet:
        /// add the word and register the mishearing in one step.
        case addWord(word: String, heard: String)
    }

    /// Folds the typographic substitutions target apps make as you type —
    /// smart quotes, curly apostrophes, en/em dashes, ellipsis, non-breaking
    /// spaces — back to the plain forms zwisp injects. Notes, for example,
    /// turns the injected straight apostrophe in "brother's" into a curly one,
    /// and without this fold the injected text can never be found again.
    public static func canonicalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2032}": result.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{2033}": result.append("\"")
            case "\u{2013}", "\u{2014}": result.append("-")
            case "\u{2026}": result.append("...")
            case "\u{00A0}": result.append(" ")
            default: result.append(ch)
            }
        }
        return result
    }

    /// The injected span's current text, re-anchored inside `current` via up
    /// to `contextChars` of surrounding baseline text. `nil` when the span
    /// can't be located any more (injected text absent from the baseline, or
    /// an anchor was itself edited away) — the caller just keeps watching.
    /// All three inputs are canonicalized first, so an app beautifying the
    /// typed quotes doesn't hide the span.
    public static func editedText(baseline rawBaseline: String, injected rawInjected: String,
                                  current rawCurrent: String, contextChars: Int) -> String? {
        let baseline = canonicalize(rawBaseline)
        let injected = canonicalize(rawInjected)
        let current = canonicalize(rawCurrent)
        guard !injected.isEmpty,
              let span = baseline.range(of: injected) else { return nil }
        let prefix = String(baseline[..<span.lowerBound].suffix(contextChars))
        let suffix = String(baseline[span.upperBound...].prefix(contextChars))

        // The prefix anchors forward from the start, the suffix backward from
        // the end — searching from opposite ends keeps an anchor from matching
        // *inside* the (possibly edited) span between them.
        let start: String.Index
        if prefix.isEmpty {
            start = current.startIndex
        } else if let found = current.range(of: prefix) {
            start = found.upperBound
        } else {
            return nil
        }
        let end: String.Index
        if suffix.isEmpty {
            end = current.endIndex
        } else if let found = current.range(of: suffix, options: .backwards),
                  found.lowerBound >= start {
            end = found.lowerBound
        } else {
            return nil
        }
        return String(current[start..<end])
    }

    /// What one in-place fix teaches the dictionary. `isKnownWord` decides
    /// whether a replacement word is ordinary vocabulary (a content edit —
    /// learn nothing) or a name/term worth keeping; the app passes the system
    /// spell checker, tests pass a fixture.
    public static func actions(
        injected: String, edited: String,
        dictionary: [DictionaryEntry],
        config: Configuration.PersonalDictionary = Configuration.PersonalDictionary(),
        isKnownWord: (String) -> Bool
    ) -> [Action] {
        var result: [Action] = []

        // Fixes onto existing dictionary words: the explicit-correction
        // pipeline already computes exactly these, with its conflict rails.
        for suggestion in CorrectionDiff.aliasSuggestions(
            injected: injected, corrected: edited,
            dictionary: dictionary, config: config) {
            result.append(.addMishearing(heard: suggestion.heard, word: suggestion.word))
        }

        // Fixes onto words zwisp doesn't know yet.
        for sub in CorrectionDiff.substitutions(from: injected, to: edited,
                                                maxWords: config.maxEntryWords) {
            let heardForm = TranscriptCorrector.normalize(sub.original)
            let saidForm = TranscriptCorrector.normalize(sub.replacement)
            guard !heardForm.isEmpty, !saidForm.isEmpty, heardForm != saidForm,
                  sub.original.count <= config.maxEntryLength,
                  sub.replacement.count <= config.maxEntryLength
            else { continue }
            // Already a dictionary word → the mishearing pass above owns it.
            guard !dictionary.contains(where: {
                TranscriptCorrector.normalize($0.word) == saidForm
            }) else { continue }
            // All-ordinary replacements are the user editing content, not
            // fixing a mishearing; one unknown word marks a term. The escape
            // hatch is a proper-noun-shaped respelling ("Riyad" → "Riyadh"):
            // names the spell checker happens to know still deserve learning.
            let words = sub.replacement.split(whereSeparator: \.isWhitespace).map(String.init)
            let anyUnknown = words.contains { !isKnownWord($0) }
            guard anyUnknown || isProperNounRespelling(sub, heardForm: heardForm,
                                                       saidForm: saidForm) else { continue }
            // Same rails addAlias enforces for the heard form.
            guard !dictionary.contains(where: {
                TranscriptCorrector.normalize($0.word) == heardForm
            }), !dictionary.contains(where: {
                $0.soundsLike.contains { TranscriptCorrector.normalize($0) == heardForm }
            }) else { continue }

            let action = Action.addWord(word: sub.replacement, heard: sub.original)
            if !result.contains(action) {
                result.append(action)
            }
        }
        return result
    }

    /// A one-word, capitalized-to-capitalized fix whose spellings nearly match
    /// (≤ 2 edits) reads as respelling a name, even when the spell checker
    /// knows the target ("Riyad" → "Riyadh"). Sentence starts don't count —
    /// capitalization is grammar there, and a fix like "Their" → "There"
    /// must never enter the dictionary (its exact-match alias would then
    /// rewrite ordinary text forever).
    private static func isProperNounRespelling(_ sub: CorrectionDiff.Substitution,
                                               heardForm: String,
                                               saidForm: String) -> Bool {
        guard !sub.atSentenceStart,
              !sub.original.contains(where: \.isWhitespace),
              !sub.replacement.contains(where: \.isWhitespace),
              sub.original.first?.isUppercase == true,
              sub.replacement.first?.isUppercase == true,
              saidForm.count >= 4
        else { return false }
        return TranscriptCorrector.damerauLevenshtein(Array(heardForm), Array(saidForm)) <= 2
    }
}
