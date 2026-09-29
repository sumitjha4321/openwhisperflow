import AppKit
import SwiftUI

/// Owns the floating status pill.
///
/// The window is a non-activating panel: it is ordered in without ever becoming
/// key, so the app the user is typing into keeps keyboard focus and the
/// synthesised paste still goes to the right place.
final class OverlayController {
    private let model = OverlayModel()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func push(level: Float) {
        model.push(level: level)
    }

    /// Shows `state`, optionally hiding again after a delay.
    func show(_ state: OverlayState, autoHideAfter delay: TimeInterval? = nil) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        guard state != .hidden else { return hide() }

        if case .recording = state {} else {
            model.resetLevels()
        }
        model.state = state
        ensurePanel()
        reposition()
        panel?.orderFrontRegardless()

        if let delay {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Updates the elapsed time without re-showing the window.
    func updateRecording(seconds: Double) {
        guard case .recording = model.state else { return }
        model.state = .recording(seconds: seconds)
        // A recording is the one state that has to stay on screen for as long
        // as it lasts, so if anything has ordered the panel out from under it
        // — a space change, another process taking the display — put it back
        // rather than leave the microphone open with nothing to show for it.
        if let panel, !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        model.state = .hidden
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Sit above normal windows and follow the user across spaces and into
        // full-screen apps.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none

        self.panel = panel
    }

    private func reposition() {
        guard let panel else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 260, height: 46)
        panel.setContentSize(size)

        // Bottom centre of whichever screen has the mouse, a little above the Dock.
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96)
        panel.setFrameOrigin(origin)
    }
}
