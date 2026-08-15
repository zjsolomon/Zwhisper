import Foundation

/// One dictation the user explicitly fixed: what the pipeline heard, what it
/// typed, and what the user says it should have been.
public struct CorrectionRecord: Codable, Equatable, Sendable {
    public let date: Date
    /// The raw transcript, before cleanup — kept so a saved pair can later
    /// evaluate the *whole* pipeline (was the miss Whisper's or cleanup's?).
    public let raw: String
    /// The final text zwisp injected.
    public let injected: String
    /// The user's edit of `injected` — the ground truth.
    public let corrected: String

    public init(date: Date, raw: String, injected: String, corrected: String) {
        self.date = date
        self.raw = raw
        self.injected = injected
        self.corrected = corrected
    }
}

/// The local correction corpus, persisted as JSON next to `stats.json`.
///
/// **This file DOES hold transcript text** — deliberately, and only for
/// dictations the user chose to correct via "Fix Last Dictation…". Each record
/// is created by that explicit act; nothing is captured passively, and the
/// file never leaves the machine. It is the raw material for mishearing
/// suggestions today and an eval corpus tomorrow.
///
/// Same durability posture as `StatsStore`: a missing or corrupt file loads as
/// empty, no public method throws — capture is best-effort and must never
/// interrupt the app.
public final class CorrectionStore {
    /// On-disk shape. `version` lets a future format migrate rather than reset.
    private struct Snapshot: Codable {
        var version: Int = 1
        var records: [CorrectionRecord] = []
    }

    private let config: Configuration.Corrections
    private let fileURL: URL
    private var snapshot: Snapshot

    /// `fileURL == nil` → `~/Library/Application Support/zwisp/corrections.json`.
    public init(config: Configuration.Corrections = .init(), fileURL: URL? = nil) {
        self.config = config
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.snapshot = Self.load(from: self.fileURL)
    }

    /// Oldest first, bounded by `Configuration.Corrections.maxStored`.
    public var records: [CorrectionRecord] { snapshot.records }

    /// Appends one corrected dictation, prunes the oldest past the cap, and
    /// persists — all best-effort.
    public func record(raw: String, injected: String, corrected: String,
                       date: Date = Date()) {
        snapshot.records.append(CorrectionRecord(
            date: date, raw: raw, injected: injected, corrected: corrected))
        if snapshot.records.count > config.maxStored {
            snapshot.records.removeFirst(snapshot.records.count - config.maxStored)
        }
        persist()
    }

    // MARK: Internals

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: a write failure must never surface to the caller.
        }
    }

    private static func load(from url: URL) -> Snapshot {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot() }   // missing or corrupt → start empty
        return decoded
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("zwisp", isDirectory: true)
            .appendingPathComponent("corrections.json")
    }
}
