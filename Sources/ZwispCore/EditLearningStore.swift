import Foundation

/// Persists whether zwisp may watch the field it just typed into and learn
/// dictionary words from in-place fixes. Mirrors `OverlayStore` semantics: an
/// **absent key means enabled** (the store only records an explicit opt-out),
/// each write persisted immediately via `didSet`.
public final class EditLearningStore {
    static let key = "editLearningEnabled"

    private let defaults: UserDefaults

    /// Whether passive edit learning is on. Persisted on every change.
    public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.key) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent key → default on. `object(forKey:)` distinguishes "never set"
        // (nil → true) from an explicit `false` the user chose.
        if let stored = defaults.object(forKey: Self.key) as? Bool {
            self.enabled = stored
        } else {
            self.enabled = true
        }
    }
}
