import Foundation

/// Turns raw trigger-key down/up events into start/stop decisions.
///
/// Kept free of AppKit and event taps so the timing rules can be exercised
/// directly in tests.
public final class TriggerRecognizer {
    public enum Action: Equatable {
        case start(Reason)
        case stop(Reason)

        public enum Reason: Equatable { case hold, toggle, limit }
    }

    public var mode: ActivationMode
    public var holdDelay: TimeInterval
    public var doubleTapWindow: TimeInterval

    /// Emitted on the main queue.
    public var onAction: ((Action) -> Void)?
    /// Injectable so tests can drive the hold delay on a manual clock.
    var scheduleHoldCheck: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var isKeyDown = false
    private var holdActive = false
    private var toggleActive = false
    private var lastReleaseTime: TimeInterval = -.greatestFiniteMagnitude
    private var pendingHoldGeneration = 0

    public init(mode: ActivationMode, holdDelay: TimeInterval, doubleTapWindow: TimeInterval) {
        self.mode = mode
        self.holdDelay = holdDelay
        self.doubleTapWindow = doubleTapWindow
    }

    public var isRecording: Bool { holdActive || toggleActive }

    public func keyDown(at now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard !isKeyDown else { return }   // ignore auto-repeat
        isKeyDown = true

        // While a toggle session is running, any press ends it.
        if toggleActive {
            toggleActive = false
            pendingHoldGeneration += 1
            lastReleaseTime = -.greatestFiniteMagnitude
            emit(.stop(.toggle))
            return
        }

        if mode.allowsDoubleTap, now - lastReleaseTime <= doubleTapWindow {
            pendingHoldGeneration += 1
            lastReleaseTime = -.greatestFiniteMagnitude
            toggleActive = true
            emit(.start(.toggle))
            return
        }

        guard mode.allowsHold else { return }

        // Recording only begins once the key has been held past the delay, so a
        // quick tap stays available as half of a double-tap.
        pendingHoldGeneration += 1
        let generation = pendingHoldGeneration
        scheduleHoldCheck(holdDelay) { [weak self] in
            guard let self, self.pendingHoldGeneration == generation,
                  self.isKeyDown, !self.toggleActive, !self.holdActive else { return }
            self.holdActive = true
            self.emit(.start(.hold))
        }
    }

    public func keyUp(at now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard isKeyDown else { return }
        isKeyDown = false
        pendingHoldGeneration += 1

        if holdActive {
            holdActive = false
            // A completed hold should not also count as a double-tap candidate.
            lastReleaseTime = -.greatestFiniteMagnitude
            emit(.stop(.hold))
            return
        }
        if toggleActive { return }
        lastReleaseTime = now
    }

    /// Stops a runaway recording that hit the duration cap.
    public func stopForLimit() {
        guard isRecording else { return }
        holdActive = false
        toggleActive = false
        pendingHoldGeneration += 1
        emit(.stop(.limit))
    }

    /// Drops all state, for example when the trigger key is reconfigured.
    public func reset() {
        isKeyDown = false
        holdActive = false
        toggleActive = false
        pendingHoldGeneration += 1
        lastReleaseTime = -.greatestFiniteMagnitude
    }

    private func emit(_ action: Action) {
        onAction?(action)
    }
}
