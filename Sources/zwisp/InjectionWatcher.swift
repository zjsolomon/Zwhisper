import AppKit
import ApplicationServices
import ZwispCore

/// Watches the text field a dictation was just typed into and reports the
/// first in-place edit of the injected span ("zeddo" fixed to "Ziedo") so the
/// app can offer to learn it. The pure anchoring/diff logic is
/// `ZwispCore.EditLearning`; this class only does the Accessibility plumbing:
/// grab the focused element at injection time, poll its `AXValue` on a timer,
/// and stop when something interesting happens or the window closes.
///
/// Silent-degradation contract, same as `FrontmostContext`: any AX failure —
/// permission missing, an app that doesn't expose its text (some web views,
/// secure fields never), the element dying — just ends the watch. Watching is
/// opportunistic; dictation never depends on it.
///
/// Privacy: the field's text is held in memory for the watch window and
/// compared, nothing more — never written anywhere. The explicit line stays:
/// only the menu's "Fix Last Dictation…" persists transcripts.
@MainActor
final class InjectionWatcher {
    private let config: Configuration.EditLearning
    /// Fired at most once per watch, with the injected text and what the user
    /// turned it into.
    private let onEdit: (_ injected: String, _ edited: String) -> Void

    private var timer: Timer?
    private var element: AXUIElement?
    private var injected = ""
    /// The field's full text once it visibly contains the injection. Captured
    /// on the first poll tick rather than synchronously: synthetic keystrokes
    /// take a moment to land in the target app.
    private var baseline: String?
    private var baselineAttempts = 0
    private var failedReads = 0
    private var deadline = Date.distantPast

    init(config: Configuration.EditLearning,
         onEdit: @escaping (_ injected: String, _ edited: String) -> Void) {
        self.config = config
        self.onEdit = onEdit
    }

    /// Starts watching the currently focused element for edits to `injected`.
    /// Called right after injection, while focus is still on the target.
    /// Replaces any watch still running from a previous dictation.
    func beginWatching(injected: String) {
        stop()
        guard !injected.isEmpty else { return }
        guard let element = Self.focusedElement() else {
            Log.write("edit watch: no focused AX element; not watching")
            return
        }
        // A hung target app must not stall zwisp's main thread on each poll.
        AXUIElementSetMessagingTimeout(element, Float(config.axTimeoutSeconds))
        self.element = element
        self.injected = injected
        baseline = nil
        baselineAttempts = 0
        failedReads = 0
        deadline = Date().addingTimeInterval(config.watchSeconds)

        let timer = Timer(timeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
        baseline = nil
    }

    // MARK: Internals

    private func tick() {
        guard let element else {
            stop()
            return
        }
        guard Date() < deadline else {
            Log.write("edit watch: window expired without edits")
            stop()
            return
        }
        guard let current = Self.stringValue(of: element),
              current.count <= config.maxFieldChars else {
            // Element gone, app quit, value unreadable, or field grown huge.
            failedReads += 1
            if failedReads >= 3 {
                Log.write("edit watch: field unreadable (this app may not expose "
                    + "its text via AX); giving up")
                stop()
            }
            return
        }
        failedReads = 0

        guard let baseline else {
            // Still waiting for the synthetic keystrokes to land. Compare
            // canonicalized: apps like Notes beautify the quotes we type.
            if EditLearning.canonicalize(current)
                .contains(EditLearning.canonicalize(injected)) {
                self.baseline = current
                Log.write("edit watch: baseline captured (\(current.count) chars)")
            } else {
                baselineAttempts += 1
                if baselineAttempts >= 3 {
                    Log.write("edit watch: field never showed the injected text; giving up")
                    stop()
                }
            }
            return
        }

        guard let edited = EditLearning.editedText(
                  baseline: baseline, injected: injected,
                  current: current, contextChars: config.contextChars),
              edited != EditLearning.canonicalize(injected) else { return }

        let injected = self.injected
        Log.write("edit watch: in-place edit detected")
        stop()
        onEdit(injected, edited)
    }

    /// The element that currently has keyboard focus, system-wide.
    private static func focusedElement() -> AXUIElement? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef else { return nil }
        return (focusedRef as! AXUIElement)
    }

    /// The element's text content, when it exposes one as a string.
    private static func stringValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef) == .success,
            let value = valueRef as? String else { return nil }
        return value
    }
}
