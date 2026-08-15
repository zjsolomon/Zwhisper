import Foundation

/// Extracts what actually changed when the user fixed a dictation, and turns
/// the high-signal changes into "sounds like" suggestions.
///
/// The diff is word-level: both texts are reduced to their word runs
/// (normalized the way `TranscriptCorrector` matches), aligned by longest
/// common subsequence, and every maximal run of words replaced by other words
/// becomes a `Substitution`. Pure insertions and deletions are ignored — the
/// user rephrasing or trimming their dictation is not a mishearing.
///
/// A substitution graduates to an `AliasSuggestion` only when it is exactly
/// the shape the dictionary can act on: the replacement spells an existing
/// dictionary word, and registering the original as its mishearing is
/// something `DictionaryStore.addAlias` would accept. Everything else stays
/// in the stored record for the future eval loop to mine.
public enum CorrectionDiff {
    /// One contiguous word-run replacement, surfaces joined by single spaces.
    public struct Substitution: Equatable {
        public let original: String     // from the injected text
        public let replacement: String  // from the corrected text
        /// Whether `original` began a sentence (first word of the text, or
        /// preceded by sentence-ending punctuation). Capitalization carries no
        /// signal there, which the proper-noun learning heuristic needs to know.
        public let atSentenceStart: Bool

        public init(original: String, replacement: String, atSentenceStart: Bool = false) {
            self.original = original
            self.replacement = replacement
            self.atSentenceStart = atSentenceStart
        }
    }

    /// "zwisp heard `heard` where you wrote the dictionary word `word`."
    public struct AliasSuggestion: Equatable {
        public let heard: String  // candidate mishearing, as the pipeline typed it
        public let word: String   // the dictionary entry's stored form

        public init(heard: String, word: String) {
            self.heard = heard
            self.word = word
        }
    }

    /// Word-run substitutions from `before` to `after`, both sides capped at
    /// `maxWords` words — longer blocks are wholesale rewrites, not terms.
    public static func substitutions(from before: String, to after: String,
                                     maxWords: Int) -> [Substitution] {
        let a = words(of: before)
        let b = words(of: after)
        guard !a.isEmpty, !b.isEmpty else { return [] }

        // Walk the aligned pairs plus an end sentinel; the gap before each
        // match is a diff block. Only blocks with words on BOTH sides are
        // substitutions.
        var result: [Substitution] = []
        var ai = 0, bi = 0
        for (ma, mb) in lcsMatches(a.map { $0.form }, b.map { $0.form }) + [(a.count, b.count)] {
            let aBlock = a[ai..<ma]
            let bBlock = b[bi..<mb]
            if !aBlock.isEmpty, aBlock.count <= maxWords,
               !bBlock.isEmpty, bBlock.count <= maxWords {
                result.append(Substitution(
                    original: aBlock.map { $0.surface }.joined(separator: " "),
                    replacement: bBlock.map { $0.surface }.joined(separator: " "),
                    atSentenceStart: aBlock.first?.startsSentence ?? false))
            }
            ai = ma + 1
            bi = mb + 1
        }
        return result
    }

    /// The substitutions in this correction that map onto the dictionary:
    /// each one is ready to hand to `DictionaryStore.addAlias`. Suggestions
    /// the store would refuse (conflicts, over-length) are filtered here so
    /// the app never proposes something it then can't add.
    public static func aliasSuggestions(
        injected: String, corrected: String,
        dictionary: [DictionaryEntry],
        config: Configuration.PersonalDictionary = Configuration.PersonalDictionary()
    ) -> [AliasSuggestion] {
        guard !dictionary.isEmpty else { return [] }
        var suggestions: [AliasSuggestion] = []
        for sub in substitutions(from: injected, to: corrected, maxWords: config.maxEntryWords) {
            let heardForm = TranscriptCorrector.normalize(sub.original)
            let saidForm = TranscriptCorrector.normalize(sub.replacement)
            // Same letters → punctuation/casing/spacing drift, not a mishearing.
            guard !heardForm.isEmpty, heardForm != saidForm else { continue }
            // The replacement must spell a dictionary word to have a home.
            guard let entry = dictionary.first(where: {
                TranscriptCorrector.normalize($0.word) == saidForm
            }) else { continue }
            // Skip what addAlias would refuse: a mishearing that spells some
            // dictionary word, one already registered anywhere, or over-length.
            guard sub.original.count <= config.maxEntryLength,
                  !dictionary.contains(where: {
                      TranscriptCorrector.normalize($0.word) == heardForm
                  }),
                  !dictionary.contains(where: {
                      $0.soundsLike.contains { TranscriptCorrector.normalize($0) == heardForm }
                  })
            else { continue }

            let suggestion = AliasSuggestion(heard: sub.original, word: entry.word)
            if !suggestions.contains(suggestion) {
                suggestions.append(suggestion)
            }
        }
        return suggestions
    }

    // MARK: - Internals

    private struct Word {
        let surface: String  // the exact run as it appears in the text
        let form: String     // lowercased — runs are already letters/digits only
        let startsSentence: Bool
    }

    /// Maximal letter/digit runs, in order — the same word unit
    /// `TranscriptCorrector` matches on; punctuation and whitespace vanish,
    /// but sentence-ending punctuation marks the following word first.
    private static func words(of text: String) -> [Word] {
        var result: [Word] = []
        var current = ""
        // The first word of the text starts a sentence by definition.
        var nextStartsSentence = true
        var gapEndedSentence = false

        func flush() {
            guard !current.isEmpty else { return }
            result.append(Word(surface: current, form: current.lowercased(),
                               startsSentence: nextStartsSentence))
            current = ""
            nextStartsSentence = false
            gapEndedSentence = false
        }

        for ch in text {
            if ch.isLetter || ch.isNumber {
                if current.isEmpty, gapEndedSentence { nextStartsSentence = true }
                current.append(ch)
            } else {
                flush()
                if ch == "." || ch == "!" || ch == "?" || ch.isNewline {
                    gapEndedSentence = true
                }
            }
        }
        flush()
        return result
    }

    /// Longest-common-subsequence alignment: index pairs of matched words, in
    /// order. Standard O(m·n) table — dictations are at most a few hundred
    /// words, so quadratic is fine.
    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let m = a.count, n = b.count
        var table = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        while i < m, j < n {
            if a[i] == b[j] {
                matches.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }
}
