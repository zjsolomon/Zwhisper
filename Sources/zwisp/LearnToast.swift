import AppKit
import Observation
import SwiftUI
import ZwispCore

/// The "adding to dictionary" countdown toast: a small pill, bottom-center
/// (just above where the dictation wave lives), announcing what zwisp is about
/// to learn, with a draining LED bar and a Cancel button. When the countdown
/// runs out the commit closure fires; Cancel means "don't add this", not just
/// "dismiss".
///
/// Unlike the dictation wave this panel must ACCEPT clicks (Cancel), but it
/// still must never take keyboard focus from the app the user is editing in —
/// `.nonactivatingPanel` plus refusing key/main gives clickable-but-never-key.

// MARK: - Panel

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Model

@MainActor
@Observable
private final class LearnToastModel {
    var title = ""
    var detail = ""
    /// Remaining countdown, 1 → 0.
    var fraction: Double = 1
}

// MARK: - View

private struct LearnToastView: View {
    let model: LearnToastModel
    let onCancel: () -> Void

    /// LED cells in the countdown bar — drains right-to-left in discrete
    /// steps, the overlay's 8-bit language (no smooth sweep).
    private static let cellCount = 14

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
                Text(model.detail)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    let lit = Int((model.fraction * Double(Self.cellCount)).rounded(.up))
                    ForEach(0..<Self.cellCount, id: \.self) { i in
                        Rectangle()   // sharp corners — the pixel look
                            .fill(Color.white)
                            .opacity(i < lit ? 0.85 : 0.16)
                            .frame(width: 9, height: 3)
                    }
                }
                .padding(.top, 3)
            }
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)   // white-on-material regardless of system theme
    }
}

// MARK: - Controller

@MainActor
final class LearnToast {
    private let config: Configuration.EditLearning
    /// Placement only: the toast sits just above the dictation wave's slot.
    private let overlayConfig: Configuration.Overlay

    private let model = LearnToastModel()
    private var panel: NonActivatingPanel?
    private var timer: Timer?
    private var endsAt = Date()
    private var onCommit: (() -> Void)?
    private var onCancel: (() -> Void)?
    private(set) var isActive = false

    /// Size the panel generously; the SwiftUI pill centers inside and the rest
    /// stays transparent (and, being a panel that accepts clicks, empty space
    /// is padding — keep it modest).
    private static let panelSize = NSSize(width: 420, height: 72)

    init(config: Configuration.EditLearning, overlayConfig: Configuration.Overlay) {
        self.config = config
        self.overlayConfig = overlayConfig
    }

    /// Shows the countdown. `onCommit` fires when it expires un-cancelled.
    /// If a toast is already up, the new request is dropped (never queue
    /// consent dialogs) — the caller treats that as "not learned".
    func present(title: String, detail: String,
                 onCommit: @escaping () -> Void,
                 onCancel: @escaping () -> Void) {
        guard !isActive else { return }
        isActive = true
        self.onCommit = onCommit
        self.onCancel = onCancel

        model.title = title
        model.detail = detail
        model.fraction = 1
        endsAt = Date().addingTimeInterval(config.toastSeconds)

        let panel = ensurePanel()
        place(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Internals

    private func tick() {
        let remaining = endsAt.timeIntervalSinceNow
        model.fraction = max(remaining / config.toastSeconds, 0)
        if remaining <= 0 {
            let commit = onCommit
            dismiss()
            commit?()
        }
    }

    private func cancelClicked() {
        let cancel = onCancel
        dismiss()
        cancel?()
    }

    private func dismiss() {
        timer?.invalidate()
        timer = nil
        onCommit = nil
        onCancel = nil
        isActive = false
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                // A newer present() may have revived the panel meanwhile.
                guard let self, !self.isActive else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func ensurePanel() -> NonActivatingPanel {
        if let panel { return panel }

        let rect = NSRect(origin: .zero, size: Self.panelSize)
        let panel = NonActivatingPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false              // Cancel must be clickable
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let hosting = NSHostingView(rootView: LearnToastView(
            model: model, onCancel: { [weak self] in self?.cancelClicked() }))
        hosting.frame = rect
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// Bottom-center of the dictation screen, one slot above the wave pill so
    /// the two never overlap.
    private func place(_ panel: NSPanel) {
        guard let screen = FrontmostContext.focusedWindowScreen()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let x = vf.midX - Self.panelSize.width / 2
        let y = vf.minY + CGFloat(overlayConfig.bottomOffset)
            + CGFloat(overlayConfig.pillHeight) + 14
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
