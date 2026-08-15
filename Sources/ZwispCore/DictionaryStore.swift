import Foundation

/// One dictionary word plus the mishearings ("sounds like" forms) the user has
/// registered for it. `word` is the exact spelling to produce; each entry in
/// `soundsLike` is a transcript form that always means `word` ("Zeddo" →
/// "Ziedo"). A bare string literal is a word with no mishearings, so callers
/// that only care about spellings can keep writing `["Ziedo", "WhisperKit"]`.
public struct DictionaryEntry: Equatable {
    public let word: String
    public let soundsLike: [String]

    public init(word: String, soundsLike: [String] = []) {
        self.word = word
        self.soundsLike = soundsLike
    }
}

extension DictionaryEntry: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(word: value)
    }
}

/// The user's personal dictionary — names and terms Whisper keeps mishearing
/// ("Ziedo", "WhisperKit") — persisted in `UserDefaults`.
///
/// Entries feed two consumers: the cleanup system prompt (the LLM is told the
/// exact spellings) and `TranscriptCorrector` (a deterministic post-pass that
/// works even when cleanup is off). Entries can arrive as arbitrary pasted
/// text, so `add` validates: a stray paragraph must not become a "word".
///
/// Each entry can also carry "sounds like" aliases — mishearings the user has
/// seen in real transcripts. Aliases are matched *exactly* (normalized) by
/// `TranscriptCorrector`, so `addAlias` must reject any alias that spells a
/// dictionary word or another word's alias: a collision would deterministically
/// rewrite legitimate text.
public final class DictionaryStore {
    /// Insertion order, which is also prompt order. Use `sortedEntries` for UI.
    public private(set) var entries: [String]

    /// Mishearings per entry, keyed by the entry's stored form, each list in
    /// the order the user added it.
    private var aliasMap: [String: [String]]

    private let config: Configuration.PersonalDictionary
    private let defaults: UserDefaults
    static let key = "personalDictionary"
    static let aliasesKey = "personalDictionaryAliases"

    /// First-run seed: the app's own name — it's lowercase, Whisper has never
    /// seen it, and it's the word every user dictates when talking about the
    /// app. Doubles as a visible example of what the dictionary is for.
    public static let defaultEntries = ["zwisp"]

    public init(config: Configuration.PersonalDictionary = Configuration.PersonalDictionary(),
                defaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = defaults
        let loaded: [String]
        if let stored = defaults.stringArray(forKey: Self.key) {
            // Key present (possibly an empty list the user cleared on purpose).
            loaded = stored
        } else {
            loaded = Self.defaultEntries
        }
        self.entries = loaded
        // Drop alias lists whose word is gone rather than resurrect them.
        let storedAliases = (defaults.dictionary(forKey: Self.aliasesKey) as? [String: [String]]) ?? [:]
        self.aliasMap = storedAliases.filter { loaded.contains($0.key) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Case-insensitively sorted, for stable menu display.
    public var sortedEntries: [String] {
        entries.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Entries in insertion (= prompt) order, each with its mishearings —
    /// the shape `TranscriptCorrector` and the cleanup system prompt consume.
    public var entriesWithAliases: [DictionaryEntry] {
        entries.map { DictionaryEntry(word: $0, soundsLike: aliasMap[$0] ?? []) }
    }

    /// The mishearings registered for `entry` (exact stored form), in the
    /// order they were added.
    public func aliases(for entry: String) -> [String] {
        aliasMap[entry] ?? []
    }

    /// What `add` did with the text — callers surface these differently (the
    /// Service shows an error only for `.rejected`; `.duplicate` is a no-op).
    public enum AddResult: Equatable {
        case added            // new entry stored
        case updated          // existed with different casing; newest casing wins
        case duplicate        // already stored verbatim; nothing changed
        case rejected         // not dictionary material; nothing stored
    }

    /// Adds a trimmed entry. Rejects text that isn't dictionary material:
    /// empty, too long, or too many words. Re-adding an existing entry with
    /// different casing *replaces* it — the user is correcting the spelling.
    @discardableResult
    public func add(_ rawEntry: String) -> AddResult {
        let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty,
              entry.count <= config.maxEntryLength,
              entry.split(whereSeparator: \.isWhitespace).count <= config.maxEntryWords
        else { return .rejected }

        if let existing = entries.firstIndex(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) {
            guard entries[existing] != entry else { return .duplicate }
            let previous = entries[existing]
            entries[existing] = entry
            // The alias map is keyed by the stored form — follow the recasing.
            if let list = aliasMap.removeValue(forKey: previous) {
                aliasMap[entry] = list
                persistAliases()
            }
            persist()
            return .updated
        }
        entries.append(entry)
        persist()
        return .added
    }

    /// Removes an entry if present (exact match — the menu passes back the
    /// stored string verbatim). Its aliases go with it.
    public func remove(_ entry: String) {
        let before = entries.count
        entries.removeAll { $0 == entry }
        if entries.count != before {
            if aliasMap.removeValue(forKey: entry) != nil { persistAliases() }
            persist()
        }
    }

    // MARK: - Aliases

    /// What `addAlias` did — parallels `AddResult`, plus `conflict` for an
    /// alias that would collide with the rest of the dictionary.
    public enum AliasAddResult: Equatable {
        case added            // new alias stored
        case updated          // existed in a different form; newest form wins
        case duplicate        // already stored verbatim; nothing changed
        case conflict         // spells a dictionary word or another word's alias
        case rejected         // unknown word, or not dictionary material
    }

    /// Registers a mishearing for `entry` (exact stored form). Validation
    /// mirrors `add` (trim, length, word count), then rejects collisions:
    /// an alias that normalizes to any dictionary word — including its own —
    /// or to another word's alias would make the corrector's exact match
    /// rewrite legitimate text or become ambiguous.
    @discardableResult
    public func addAlias(_ rawAlias: String, for entry: String) -> AliasAddResult {
        let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entries.contains(entry),
              !alias.isEmpty,
              alias.count <= config.maxEntryLength,
              alias.split(whereSeparator: \.isWhitespace).count <= config.maxEntryWords
        else { return .rejected }

        let form = TranscriptCorrector.normalize(alias)
        guard !form.isEmpty else { return .rejected }

        if entries.contains(where: { TranscriptCorrector.normalize($0) == form }) {
            return .conflict
        }
        for (word, list) in aliasMap where word != entry {
            if list.contains(where: { TranscriptCorrector.normalize($0) == form }) {
                return .conflict
            }
        }

        var list = aliasMap[entry] ?? []
        if let existing = list.firstIndex(where: { TranscriptCorrector.normalize($0) == form }) {
            guard list[existing] != alias else { return .duplicate }
            list[existing] = alias
            aliasMap[entry] = list
            persistAliases()
            return .updated
        }
        list.append(alias)
        aliasMap[entry] = list
        persistAliases()
        return .added
    }

    /// Removes an alias from `entry` if present (both exact stored forms).
    public func removeAlias(_ alias: String, for entry: String) {
        guard var list = aliasMap[entry] else { return }
        let before = list.count
        list.removeAll { $0 == alias }
        guard list.count != before else { return }
        aliasMap[entry] = list.isEmpty ? nil : list
        persistAliases()
    }

    private func persist() {
        defaults.set(entries, forKey: Self.key)
    }

    private func persistAliases() {
        defaults.set(aliasMap, forKey: Self.aliasesKey)
    }
}
