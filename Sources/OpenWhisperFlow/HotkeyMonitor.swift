import Foundation
import CoreGraphics
import ApplicationServices
import DictationCore

/// Watches the keyboard system-wide for the configured trigger key.
///
/// A session-level `CGEventTap` sees keys no matter which app is focused, and it
/// belongs to this process rather than to any window — so holding the trigger
/// while switching apps keeps the recording running, which is the behaviour the
/// hold-to-talk flow depends on.
public final class HotkeyMonitor {
    public private(set) var trigger: HotkeyTrigger
    public var suppressTriggerKey: Bool

    public var onKeyDown: (() -> Void)?
    public var onKeyUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Modifier flags are reported as a whole word, so the previous held state
    /// is tracked to turn them into discrete down/up events.
    private var modifierWasHeld = false

    public init(trigger: HotkeyTrigger, suppressTriggerKey: Bool) {
        self.trigger = trigger
        self.suppressTriggerKey = suppressTriggerKey
    }

    deinit { stop() }

    public var isRunning: Bool { tap != nil }

    /// Starts the tap. Requires Accessibility permission; returns false without it.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // An active tap is used even when not suppressing, so that a single
            // Accessibility grant covers both listening and the paste keystroke.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        modifierWasHeld = false
    }

    public func update(trigger: HotkeyTrigger, suppressTriggerKey: Bool) {
        self.trigger = trigger
        self.suppressTriggerKey = suppressTriggerKey
        modifierWasHeld = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or when input is grabbed;
        // re-enabling keeps the hotkey alive for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let passThrough = Unmanaged.passUnretained(event)

        if trigger.isModifier {
            guard type == .flagsChanged, keyCode == trigger.keyCode else { return passThrough }
            let held = trigger.isHeld(flags: event.flags)
            guard held != modifierWasHeld else { return passThrough }
            modifierWasHeld = held
            deliver(held ? .down : .up)
            return suppressTriggerKey ? nil : passThrough
        }

        guard keyCode == trigger.keyCode else { return passThrough }
        switch type {
        case .keyDown:
            // Auto-repeat would otherwise look like a rapid tap sequence.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return suppressTriggerKey ? nil : passThrough
            }
            deliver(.down)
        case .keyUp:
            deliver(.up)
        default:
            return passThrough
        }
        return suppressTriggerKey ? nil : passThrough
    }

    private enum Edge { case down, up }

    private func deliver(_ edge: Edge) {
        // The tap callback runs on the run loop it was added to; hop explicitly
        // so downstream state is only ever touched on the main queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch edge {
            case .down: self.onKeyDown?()
            case .up: self.onKeyUp?()
            }
        }
    }
}
