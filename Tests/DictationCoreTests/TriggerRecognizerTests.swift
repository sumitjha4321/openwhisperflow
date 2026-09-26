import Foundation
import Testing
@testable import DictationCore

/// Drives `TriggerRecognizer` with a manual clock: the hold check is captured
/// rather than scheduled, so the timing rules are tested without waiting.
private final class Harness {
    let recognizer: TriggerRecognizer
    var actions: [TriggerRecognizer.Action] = []
    private var pendingHoldChecks: [() -> Void] = []

    init(mode: ActivationMode) {
        recognizer = TriggerRecognizer(mode: mode, holdDelay: 0.14, doubleTapWindow: 0.32)
        recognizer.onAction = { [weak self] action in self?.actions.append(action) }
        recognizer.scheduleHoldCheck = { [weak self] _, work in self?.pendingHoldChecks.append(work) }
    }

    /// Simulates the hold delay elapsing.
    func fireHoldChecks() {
        let checks = pendingHoldChecks
        pendingHoldChecks = []
        for check in checks { check() }
    }

    var hasPendingHoldCheck: Bool { !pendingHoldChecks.isEmpty }
}

@Suite("Trigger recognizer")
struct TriggerRecognizerTests {
    @Test("Holding past the delay starts, releasing stops")
    func holdStartsAndStops() {
        let harness = Harness(mode: .holdAndDoubleTap)

        harness.recognizer.keyDown(at: 0)
        #expect(harness.actions.isEmpty, "recording should wait for the hold delay")

        harness.fireHoldChecks()
        #expect(harness.actions == [.start(.hold)])
        #expect(harness.recognizer.isRecording)

        harness.recognizer.keyUp(at: 2.0)
        #expect(harness.actions == [.start(.hold), .stop(.hold)])
        #expect(!harness.recognizer.isRecording)
    }

    @Test("A tap shorter than the hold delay records nothing")
    func quickTapDoesNotRecord() {
        let harness = Harness(mode: .holdAndDoubleTap)

        harness.recognizer.keyDown(at: 0)
        harness.recognizer.keyUp(at: 0.05)
        harness.fireHoldChecks()   // the pending check is now stale

        #expect(harness.actions.isEmpty)
        #expect(!harness.recognizer.isRecording)
    }

    @Test("Double-tap starts a hands-free session that a later tap ends")
    func doubleTapToggles() {
        let harness = Harness(mode: .holdAndDoubleTap)

        harness.recognizer.keyDown(at: 0)
        harness.recognizer.keyUp(at: 0.05)
        harness.recognizer.keyDown(at: 0.12)
        #expect(harness.actions == [.start(.toggle)])

        harness.recognizer.keyUp(at: 0.16)
        #expect(harness.actions == [.start(.toggle)], "releasing must not end a toggle session")
        #expect(harness.recognizer.isRecording)

        harness.recognizer.keyDown(at: 5.0)
        #expect(harness.actions == [.start(.toggle), .stop(.toggle)])
        #expect(!harness.recognizer.isRecording)
    }

    @Test("A second tap after the window is a hold, not a toggle")
    func lateSecondTapIsAHold() {
        let harness = Harness(mode: .holdAndDoubleTap)

        harness.recognizer.keyDown(at: 0)
        harness.recognizer.keyUp(at: 0.05)
        harness.recognizer.keyDown(at: 1.0)
        #expect(harness.actions.isEmpty)

        harness.fireHoldChecks()
        #expect(harness.actions == [.start(.hold)])
    }

    @Test("A finished hold does not arm a double-tap")
    func completedHoldIsNotADoubleTapCandidate() {
        let harness = Harness(mode: .holdAndDoubleTap)

        harness.recognizer.keyDown(at: 0)
        harness.fireHoldChecks()
        harness.recognizer.keyUp(at: 1.0)
        #expect(harness.actions == [.start(.hold), .stop(.hold)])

        // Pressing again immediately must read as a new hold, not a second tap.
        harness.recognizer.keyDown(at: 1.05)
        #expect(harness.actions == [.start(.hold), .stop(.hold)])
        harness.fireHoldChecks()
        #expect(harness.actions == [.start(.hold), .stop(.hold), .start(.hold)])
    }

    @Test("Hold-only mode ignores double-taps")
    func holdOnlyIgnoresDoubleTap() {
        let harness = Harness(mode: .hold)

        harness.recognizer.keyDown(at: 0)
        harness.recognizer.keyUp(at: 0.05)
        harness.recognizer.keyDown(at: 0.12)
        #expect(harness.actions.isEmpty)

        harness.fireHoldChecks()
        #expect(harness.actions == [.start(.hold)])
    }

    @Test("Double-tap-only mode ignores holds")
    func doubleTapOnlyIgnoresHold() {
        let harness = Harness(mode: .doubleTapToggle)

        harness.recognizer.keyDown(at: 0)
        #expect(!harness.hasPendingHoldCheck, "no hold check should be scheduled")
        harness.fireHoldChecks()
        #expect(harness.actions.isEmpty)

        harness.recognizer.keyUp(at: 0.05)
        harness.recognizer.keyDown(at: 0.12)
        #expect(harness.actions == [.start(.toggle)])
    }

    @Test("Key auto-repeat does not start a second recording")
    func autoRepeatIsIgnored() {
        let harness = Harness(mode: .holdAndDoubleTap)

        harness.recognizer.keyDown(at: 0)
        harness.recognizer.keyDown(at: 0.03)
        harness.recognizer.keyDown(at: 0.06)
        harness.fireHoldChecks()

        #expect(harness.actions == [.start(.hold)])
    }

    @Test("The duration cap stops a running recording")
    func limitStopsRecording() {
        let harness = Harness(mode: .holdAndDoubleTap)

        harness.recognizer.keyDown(at: 0)
        harness.fireHoldChecks()
        harness.recognizer.stopForLimit()

        #expect(harness.actions == [.start(.hold), .stop(.limit)])
        #expect(!harness.recognizer.isRecording)
    }

    @Test("The duration cap does nothing when idle")
    func limitIsIgnoredWhenIdle() {
        let harness = Harness(mode: .holdAndDoubleTap)
        harness.recognizer.stopForLimit()
        #expect(harness.actions.isEmpty)
    }

    @Test("Reset cancels a pending hold")
    func resetCancelsPendingHold() {
        let harness = Harness(mode: .holdAndDoubleTap)

        harness.recognizer.keyDown(at: 0)
        harness.recognizer.reset()
        harness.fireHoldChecks()

        #expect(harness.actions.isEmpty)
        #expect(!harness.recognizer.isRecording)
    }
}

@Suite("Hotkey trigger")
struct HotkeyTriggerTests {
    @Test("Fn is a modifier key")
    func fnIsAModifier() {
        #expect(HotkeyTrigger.fn.isModifier)
        #expect(HotkeyTrigger.fn.keyCode == 63)
    }

    @Test("Function keys are not modifiers")
    func functionKeyIsNotAModifier() {
        #expect(!HotkeyTrigger(keyCode: 105, label: "F13").isModifier)
    }

    @Test("Held state is read from the flag bit")
    func heldStateFromFlags() {
        let fn = HotkeyTrigger.fn
        #expect(fn.isHeld(flags: .maskSecondaryFn))
        #expect(!fn.isHeld(flags: []))
        #expect(!fn.isHeld(flags: .maskAlternate), "Option must not look like Fn")
    }

    @Test("Left and right modifiers are told apart")
    func leftAndRightAreDistinct() {
        let left = HotkeyTrigger(keyCode: 58, label: "Left Option")
        let right = HotkeyTrigger(keyCode: 61, label: "Right Option")
        #expect(left.modifierMask != right.modifierMask)
    }

    @Test("Every preset has a usable label")
    func presetsAreLabelled() {
        for preset in HotkeyTrigger.presets {
            #expect(!preset.label.isEmpty)
            #expect(HotkeyTrigger.label(forKeyCode: preset.keyCode) == preset.label)
        }
    }
}

@Suite("Preferences")
struct PreferencesTests {
    @Test("Defaults are hold-plus-double-tap on Fn")
    func defaults() {
        let preferences = Preferences()
        #expect(preferences.trigger == .fn)
        #expect(preferences.activationMode == .holdAndDoubleTap)
        #expect(preferences.pasteIntoFocusedApp)
        #expect(preferences.copyToClipboard)
    }

    @Test("Round-trips through JSON")
    func codableRoundTrip() throws {
        var preferences = Preferences()
        preferences.trigger = HotkeyTrigger(keyCode: 61, label: "Right Option")
        preferences.activationMode = .hold
        preferences.holdDelayMilliseconds = 200

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded == preferences)
    }

    @Test("A settings file missing newer keys keeps the values it does have")
    func decodingToleratesMissingKeys() throws {
        // What an older build would have written: no showDockIcon field.
        let stored = """
        {
          "trigger": { "keyCode": 61, "label": "Right Option" },
          "activationMode": "hold",
          "holdDelayMilliseconds": 200,
          "playSounds": false
        }
        """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(stored.utf8))

        // Stored values survive...
        #expect(decoded.trigger.keyCode == 61)
        #expect(decoded.activationMode == .hold)
        #expect(decoded.holdDelayMilliseconds == 200)
        #expect(!decoded.playSounds)
        // ...and absent fields fall back to their defaults rather than
        // failing the decode and discarding everything.
        #expect(decoded.showDockIcon == Preferences().showDockIcon)
        #expect(decoded.engineID == Preferences().engineID)
        #expect(decoded.copyToClipboard)
    }

    @Test("An old settings file's modelID becomes the engine id")
    func legacyModelIDMigrates() throws {
        // Written by a build that predates the engine picker.
        let stored = """
        { "modelID": "moonshine-tiny-quantized", "playSounds": false }
        """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(stored.utf8))
        #expect(decoded.engineID == "moonshine-tiny-quantized")
        #expect(!decoded.playSounds)
    }

    @Test("A new engineID wins over a legacy modelID")
    func engineIDTakesPrecedence() throws {
        let stored = """
        { "engineID": "apple-dictation", "modelID": "moonshine-tiny-quantized" }
        """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(stored.utf8))
        #expect(decoded.engineID == "apple-dictation")
    }

    @Test("Encoding does not write the legacy key back out")
    func encodingDropsLegacyKey() throws {
        var preferences = Preferences()
        preferences.engineID = "whisper-small-en"
        let data = try JSONEncoder().encode(preferences)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["engineID"] as? String == "whisper-small-en")
        #expect(object?["modelID"] == nil)
    }

    @Test("A corrupted field does not discard the rest")
    func decodingToleratesBadValues() throws {
        let stored = """
        { "activationMode": "nonsense", "holdDelayMilliseconds": 250 }
        """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(stored.utf8))
        #expect(decoded.activationMode == Preferences().activationMode)
        #expect(decoded.holdDelayMilliseconds == 250)
    }

    @Test("Millisecond settings convert to seconds")
    func timeConversion() {
        var preferences = Preferences()
        preferences.holdDelayMilliseconds = 250
        preferences.doubleTapWindowMilliseconds = 400
        #expect(abs(preferences.holdDelay - 0.25) < 1e-9)
        #expect(abs(preferences.doubleTapWindow - 0.4) < 1e-9)
    }
}
