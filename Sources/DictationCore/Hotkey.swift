import Foundation
import CoreGraphics

/// The key that starts dictation.
///
/// Modifier keys (Fn, Option, Control…) are recognised from `flagsChanged`
/// events, where the event's key code identifies exactly which physical key
/// moved and a device-dependent flag bit says whether it went down or up. That
/// bit is what makes left/right modifiers distinguishable — the public masks
/// such as `.maskAlternate` do not tell the two sides apart.
public struct HotkeyTrigger: Codable, Hashable {
    public var keyCode: UInt16
    public var label: String

    public init(keyCode: UInt16, label: String) {
        self.keyCode = keyCode
        self.label = label
    }

    /// Flag bit that is set while the given modifier key is held, if it is one.
    public static let modifierMasks: [UInt16: UInt64] = [
        63: 0x8000_00,   // Fn / Globe
        57: 0x01_0000,   // Caps Lock
        56: 0x02,        // Left Shift
        60: 0x04,        // Right Shift
        59: 0x01,        // Left Control
        62: 0x2000,      // Right Control
        58: 0x20,        // Left Option
        61: 0x40,        // Right Option
        55: 0x08,        // Left Command
        54: 0x10,        // Right Command
    ]

    public var isModifier: Bool { Self.modifierMasks[keyCode] != nil }
    public var modifierMask: UInt64? { Self.modifierMasks[keyCode] }

    /// Returns whether this trigger is currently held, given a flags value.
    public func isHeld(flags: CGEventFlags) -> Bool {
        guard let mask = modifierMask else { return false }
        return flags.rawValue & mask == mask
    }

    public static let fn = HotkeyTrigger(keyCode: 63, label: "Fn (Globe)")

    public static let presets: [HotkeyTrigger] = [
        .fn,
        HotkeyTrigger(keyCode: 61, label: "Right Option"),
        HotkeyTrigger(keyCode: 54, label: "Right Command"),
        HotkeyTrigger(keyCode: 62, label: "Right Control"),
        HotkeyTrigger(keyCode: 60, label: "Right Shift"),
        HotkeyTrigger(keyCode: 105, label: "F13"),
        HotkeyTrigger(keyCode: 107, label: "F14"),
    ]

    /// Best-effort name for an arbitrary key, for the "press a key" recorder.
    public static func label(forKeyCode code: UInt16) -> String {
        if let preset = presets.first(where: { $0.keyCode == code }) { return preset.label }
        let named: [UInt16: String] = [
            58: "Left Option", 55: "Left Command", 59: "Left Control", 56: "Left Shift",
            57: "Caps Lock", 53: "Escape", 49: "Space", 36: "Return", 48: "Tab",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            113: "F15", 106: "F16", 279: "Unknown",
        ]
        return named[code] ?? "Key \(code)"
    }
}

/// How holding or tapping the trigger maps onto recording.
public enum ActivationMode: String, Codable, CaseIterable, Identifiable {
    /// Record while the key is held; transcribe on release.
    case hold
    /// Tap twice to start, tap once to stop. Hands-free for long dictation.
    case doubleTapToggle
    /// Both of the above.
    case holdAndDoubleTap

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hold: return "Hold to talk"
        case .doubleTapToggle: return "Double-tap to toggle"
        case .holdAndDoubleTap: return "Hold to talk, double-tap to toggle"
        }
    }

    public var allowsHold: Bool { self != .doubleTapToggle }
    public var allowsDoubleTap: Bool { self != .hold }
}
