import Foundation
import Testing
@testable import ZwispCore

struct DictionaryStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
    }

    @Test func startsWithTheDefaultSeed() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.entries == DictionaryStore.defaultEntries)
        #expect(store.entries == ["zwisp"])
    }

    @Test func explicitlyEmptiedDictionaryStaysEmpty() {
        // Removing the seed is a choice, not a first run — respect it.
        let defaults = freshDefaults()
        let first = DictionaryStore(defaults: defaults)
        first.remove("zwisp")

        let second = DictionaryStore(defaults: defaults)
        #expect(second.isEmpty)
    }

    @Test func addTrimsWhitespaceAndStores() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("  Ziedo \n") == .added)
        #expect(store.entries == ["zwisp", "Ziedo"])
    }

    @Test func addRejectsEmptyAndWhitespaceOnly() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("") == .rejected)
        #expect(store.add("   \n\t") == .rejected)
        #expect(store.entries == ["zwisp"])
    }

    @Test func addRejectsOverlongText() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add(String(repeating: "a", count: 65)) == .rejected)
        #expect(store.add(String(repeating: "a", count: 64)) == .added)
    }

    @Test func addRejectsTooManyWords() {
        // A Services selection can be an arbitrary sentence; that's not a term.
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("this is five whole words") == .rejected)
        #expect(store.add("Dr. Jan van Dam") == .added)
    }

    @Test func addReportsVerbatimDuplicatesWithoutStoringTwice() {
        let store = DictionaryStore(defaults: freshDefaults())
        #expect(store.add("WhisperKit") == .added)
        #expect(store.add("WhisperKit") == .duplicate)
        #expect(store.entries == ["zwisp", "WhisperKit"])
    }

    @Test func reAddingWithDifferentCasingReplacesInPlace() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("whisperkit")
        store.add("Ziedo")
        #expect(store.add("WhisperKit") == .updated)
        #expect(store.entries == ["zwisp", "WhisperKit", "Ziedo"])
    }

    @Test func removeDeletesOnlyTheExactEntry() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("Ziedo")
        store.add("WhisperKit")
        store.remove("Ziedo")
        #expect(store.entries == ["zwisp", "WhisperKit"])
        store.remove("not present")
        #expect(store.entries == ["zwisp", "WhisperKit"])
    }

    @Test func changesPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = DictionaryStore(defaults: defaults)
        first.add("Ziedo")
        first.add("WhisperKit")
        first.remove("Ziedo")

        let second = DictionaryStore(defaults: defaults)
        #expect(second.entries == ["zwisp", "WhisperKit"])
    }

    @Test func sortedEntriesIgnoreCase() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("zwisp")
        store.add("Anthropic")
        store.add("ollama")
        #expect(store.sortedEntries == ["Anthropic", "ollama", "zwisp"])
    }

    // MARK: - Sounds-like aliases

    @Test func aliasesRoundTripAndKeepOrder() {
        let defaults = freshDefaults()
        let store = DictionaryStore(defaults: defaults)
        store.add("Ziedo")
        #expect(store.addAlias("Zeddo", for: "Ziedo") == .added)
        #expect(store.addAlias("Zetto", for: "Ziedo") == .added)
        #expect(store.aliases(for: "Ziedo") == ["Zeddo", "Zetto"])
        #expect(store.entriesWithAliases == [
            DictionaryEntry(word: "zwisp"),
            DictionaryEntry(word: "Ziedo", soundsLike: ["Zeddo", "Zetto"]),
        ])

        let second = DictionaryStore(defaults: defaults)
        #expect(second.aliases(for: "Ziedo") == ["Zeddo", "Zetto"])
    }

    @Test func aliasValidationMirrorsAdd() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("Ziedo")
        #expect(store.addAlias("Zeddo", for: "unknown") == .rejected)
        #expect(store.addAlias("   ", for: "Ziedo") == .rejected)
        #expect(store.addAlias("...", for: "Ziedo") == .rejected)
        #expect(store.addAlias(String(repeating: "a", count: 65), for: "Ziedo") == .rejected)
        #expect(store.addAlias("this is five whole words", for: "Ziedo") == .rejected)
        #expect(store.aliases(for: "Ziedo").isEmpty)
    }

    @Test func aliasConflictsAreRefused() {
        // An alias that spells a dictionary word — its own or another — or an
        // alias already claimed by another word would make the corrector's
        // exact match rewrite legitimate text.
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("Ziedo")
        store.add("WhisperKit")
        #expect(store.addAlias("ziedo.", for: "Ziedo") == .conflict)
        #expect(store.addAlias("whisper-kit", for: "Ziedo") == .conflict)
        store.addAlias("Zeddo", for: "Ziedo")
        #expect(store.addAlias("zeddo", for: "WhisperKit") == .conflict)
        // Multi-word aliases are allowed ("the whisp" for "zwisp").
        #expect(store.addAlias("the whisp", for: "zwisp") == .added)
    }

    @Test func aliasDuplicateAndRecasingMatchEntrySemantics() {
        let store = DictionaryStore(defaults: freshDefaults())
        store.add("Ziedo")
        store.addAlias("zeddo", for: "Ziedo")
        #expect(store.addAlias("zeddo", for: "Ziedo") == .duplicate)
        #expect(store.addAlias("Zeddo", for: "Ziedo") == .updated)
        #expect(store.aliases(for: "Ziedo") == ["Zeddo"])
    }

    @Test func aliasesFollowARecasedWordAndDieWithARemovedOne() {
        let defaults = freshDefaults()
        let store = DictionaryStore(defaults: defaults)
        store.add("whisperkit")
        store.addAlias("whisper git", for: "whisperkit")
        #expect(store.add("WhisperKit") == .updated)
        #expect(store.aliases(for: "WhisperKit") == ["whisper git"])

        store.remove("WhisperKit")
        store.add("WhisperKit")
        #expect(store.aliases(for: "WhisperKit").isEmpty)
        // And a fresh instance must not resurrect the orphaned list either.
        #expect(DictionaryStore(defaults: defaults).aliases(for: "WhisperKit").isEmpty)
    }
}
