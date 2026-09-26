import Foundation
import AppKit
import CoreGraphics

/// Delivers finished text to wherever the user was typing.
///
/// Insertion goes through the clipboard plus a synthetic Command-V, which is
/// what works across native, Electron and web text fields alike. This app never
/// takes focus — the menu bar item and the overlay are both non-activating — so
/// the keystroke lands in whichever app the user was already using.
public enum TextInjector {
    public static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies `text`, presses Command-V, and optionally puts the old clipboard back.
    public static func paste(_ text: String, restorePrevious: Bool) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem]? = restorePrevious ? snapshot(pasteboard) : nil

        copyToClipboard(text)
        sendCommandV()

        guard let saved else { return }
        // The paste is asynchronous in the target app, so the old contents go
        // back only after it has had a chance to read the pasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var wroteSomething = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    wroteSomething = true
                }
            }
            return wroteSomething ? copy : nil
        }
    }

    private static let vKeyCode: CGKeyCode = 9

    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Suppress the local keyboard state so a trigger key the user is still
        // holding cannot contaminate the synthesised chord.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
