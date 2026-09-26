import Foundation
import AppKit
import DictationCore
import TranscriptionEngines

/// Coordinates the whole dictation flow: trigger key, microphone, model, output.
@MainActor
public final class DictationController: ObservableObject {
    public enum Status: Equatable {
        case needsPermissions
        case needsSetup(String)
        case preparing(String)
        case idle
        case recording
        case transcribing
        case failed(String)

        public var menuLabel: String {
            switch self {
            case .needsPermissions: return "Permissions needed"
            case .needsSetup(let detail): return detail
            case .preparing(let detail): return detail
            case .idle: return "Ready"
            case .recording: return "Recording…"
            case .transcribing: return "Transcribing…"
            case .failed(let message): return "Error: \(message)"
            }
        }
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var lastTranscript: String = ""
    @Published public private(set) var downloadFraction: Double?

    private let overlay = OverlayController()
    private let recorder = AudioRecorder()
    private var monitor: HotkeyMonitor
    private var recognizer: TriggerRecognizer

    /// The selected engine, once downloaded and loaded.
    private var engine: (any TranscriptionEngine)?
    private var loadedEngineID: String?
    private var isPreparingEngine = false
    /// Cached because the install check is asynchronous and the UI reads it.
    @Published public private(set) var selectedEngineIsInstalled = false

    private var recordingStarted: Date?
    private var recordingTimer: Timer?
    /// Deferred microphone teardown after a tap that did not start recording.
    private var pendingMicStandDown: DispatchWorkItem?

    private var preferences: Preferences { PreferencesStore.shared.current }

    public init() {
        let current = PreferencesStore.shared.current
        monitor = HotkeyMonitor(trigger: current.trigger, suppressTriggerKey: current.suppressTriggerKey)
        recognizer = TriggerRecognizer(
            mode: current.activationMode,
            holdDelay: current.holdDelay,
            doubleTapWindow: current.doubleTapWindow)

        monitor.onKeyDown = { [weak self] in self?.handleKeyDown() }
        monitor.onKeyUp = { [weak self] in self?.handleKeyUp() }
        recognizer.onAction = { [weak self] action in self?.handle(action) }
        recorder.onLevel = { [weak self] level in self?.overlay.push(level: level) }

        NotificationCenter.default.addObserver(
            forName: PreferencesStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    // MARK: - Lifecycle

    public func start() {
        refreshStatus()
        startMonitoringIfPossible()
        Task { await refreshInstallState(loadIfReady: true) }
    }

    /// Attaches the global key tap. Returns false if Accessibility is missing.
    @discardableResult
    public func startMonitoringIfPossible() -> Bool {
        guard Permissions.hasAccessibility else {
            monitor.stop()
            return false
        }
        return monitor.start()
    }

    public var isMonitoring: Bool { monitor.isRunning }

    /// The engine the user has chosen, falling back when it is unavailable.
    public var selectedOption: EngineOption { EngineCatalog.option(id: preferences.engineID) }

    private func settingsChanged() {
        let current = preferences
        monitor.update(trigger: current.trigger, suppressTriggerKey: current.suppressTriggerKey)
        recognizer.mode = current.activationMode
        recognizer.holdDelay = current.holdDelay
        recognizer.doubleTapWindow = current.doubleTapWindow
        recognizer.reset()

        // Switching engines drops the loaded one and re-checks the new choice.
        if loadedEngineID != nil, loadedEngineID != selectedOption.id {
            engine = nil
            loadedEngineID = nil
            Task { await refreshInstallState(loadIfReady: true) }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        // Never clobber a live recording or an in-flight preparation.
        switch status {
        case .recording, .transcribing: return
        default: break
        }
        if isPreparingEngine { return }
        status = computedStatus()
    }

    private func computedStatus() -> Status {
        if !Permissions.allGranted { return .needsPermissions }
        if engine != nil { return .idle }
        if isPreparingEngine { return .preparing("Preparing \(selectedOption.name)…") }
        if selectedEngineIsInstalled { return .preparing("Preparing \(selectedOption.name)…") }
        return .needsSetup("\(selectedOption.name) needs setting up")
    }

    // MARK: - Engine

    /// Re-reads whether the chosen engine is downloaded, and optionally loads it.
    public func refreshInstallState(loadIfReady: Bool = false) async {
        let option = selectedOption
        let installed = await EngineLoader.isInstalled(option)
        selectedEngineIsInstalled = installed
        if loadIfReady, installed, engine == nil {
            prepareSelectedEngine()
        } else {
            refreshStatus()
        }
    }

    /// Downloads whatever the chosen engine needs, then loads it.
    public func prepareSelectedEngine() {
        guard !isPreparingEngine else { return }
        let option = selectedOption
        if engine != nil, loadedEngineID == option.id { return }

        isPreparingEngine = true
        downloadFraction = nil
        status = .preparing("Preparing \(option.name)…")

        Task { [weak self] in
            do {
                let loaded = try await EngineLoader.load(option) { update in
                    Task { @MainActor in self?.apply(update) }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.engine = loaded
                    self.loadedEngineID = option.id
                    self.selectedEngineIsInstalled = true
                    self.isPreparingEngine = false
                    self.downloadFraction = nil
                    self.status = self.computedStatus()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isPreparingEngine = false
                    self.downloadFraction = nil
                    self.status = .failed("\(error)")
                }
            }
        }
    }

    private func apply(_ update: EnginePreparation) {
        switch update {
        case .checking:
            break
        case .downloading(let fraction, let detail):
            downloadFraction = fraction
            if let fraction {
                status = .preparing("\(detail) — \(Int(fraction * 100))%")
            } else {
                status = .preparing(detail)
            }
        case .loading(let detail):
            downloadFraction = nil
            status = .preparing(detail)
        case .ready:
            downloadFraction = nil
        }
    }

    /// Removes a downloaded engine's files.
    public func removeDownload(_ option: EngineOption) async {
        if loadedEngineID == option.id {
            engine = nil
            loadedEngineID = nil
        }
        try? EngineLoader.removeDownload(option)
        await refreshInstallState()
    }

    /// Description of what is loaded, for the diagnostics output.
    public var loadedEngineDescription: String? { engine?.loadedDescription }

    // MARK: - Trigger handling

    private func handleKeyDown() {
        pendingMicStandDown?.cancel()
        pendingMicStandDown = nil
        // The microphone opens on key-down, before the hold delay decides this
        // is a real dictation, so no speech is lost at the start.
        if !recognizer.isRecording {
            try? recorder.warmUp()
        }
        recognizer.keyDown()
    }

    private func handleKeyUp() {
        recognizer.keyUp()
        guard !recognizer.isRecording, recorder.isCapturing else { return }

        // This tap did not start a recording. The microphone is left open for
        // the length of the double-tap window rather than closed immediately:
        // stopping and restarting the audio engine blocks the main thread, and
        // an incidental tap of a key like Fn should not cost that — nor should
        // the first half of a double-tap.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.recognizer.isRecording else { return }
            self.recorder.cancel()
        }
        pendingMicStandDown = work
        let grace = max(preferences.doubleTapWindow, 0.2) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    private func handle(_ action: TriggerRecognizer.Action) {
        switch action {
        case .start:
            beginRecording()
        case .stop:
            endRecording()
        }
    }

    private func beginRecording() {
        pendingMicStandDown?.cancel()
        pendingMicStandDown = nil

        guard engine != nil else {
            recorder.cancel()
            recognizer.reset()
            let message = isPreparingEngine || selectedEngineIsInstalled
                ? "\(selectedOption.name) is still getting ready"
                : "Open Preferences to set up \(selectedOption.name)"
            overlay.show(.failure(message: message), autoHideAfter: 3)
            return
        }
        guard Permissions.hasMicrophone else {
            recorder.cancel()
            recognizer.reset()
            overlay.show(.failure(message: "Microphone access denied"), autoHideAfter: 3)
            return
        }

        do {
            try recorder.warmUp()
        } catch {
            recognizer.reset()
            overlay.show(.failure(message: "\(error)"), autoHideAfter: 3)
            return
        }

        recorder.confirm()
        recordingStarted = Date()
        status = .recording
        if preferences.showOverlay {
            overlay.show(.recording(seconds: 0))
        }
        if preferences.playSounds {
            NSSound(named: "Tink")?.play()
        }

        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickRecording() }
        }
    }

    private func tickRecording() {
        guard let started = recordingStarted else { return }
        let elapsed = Date().timeIntervalSince(started)
        if preferences.showOverlay {
            overlay.updateRecording(seconds: elapsed)
        }
        if elapsed >= Double(preferences.maximumRecordingSeconds) {
            recognizer.stopForLimit()
        }
    }

    private func endRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStarted = nil

        let samples = recorder.finish()
        guard let engine else {
            status = computedStatus()
            overlay.hide()
            return
        }

        let seconds = Double(samples.count) / AudioSpec.sampleRate
        guard seconds >= 0.25 else {
            status = computedStatus()
            if preferences.showOverlay {
                overlay.show(.failure(message: "Too short — hold the key while speaking"), autoHideAfter: 2)
            } else {
                overlay.hide()
            }
            return
        }

        status = .transcribing
        if preferences.showOverlay {
            overlay.show(.transcribing)
        }

        Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await engine.transcribe(samples: samples))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self?.finishTranscription(result) }
        }
    }

    private func finishTranscription(_ result: Result<String, Error>) {
        switch result {
        case .failure(let error):
            status = .failed("\(error)")
            overlay.show(.failure(message: "Transcription failed: \(error)"), autoHideAfter: 4)

        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            status = computedStatus()

            guard !text.isEmpty else {
                if preferences.showOverlay {
                    overlay.show(.failure(message: "No speech detected"), autoHideAfter: 2)
                } else {
                    overlay.hide()
                }
                return
            }

            lastTranscript = text
            let current = preferences
            var notes: [String] = []

            if current.pasteIntoFocusedApp {
                TextInjector.paste(text, restorePrevious: current.restoreClipboardAfterPaste)
                notes.append("Pasted")
                if current.copyToClipboard, !current.restoreClipboardAfterPaste {
                    notes.append("copied to clipboard")
                }
            } else if current.copyToClipboard {
                TextInjector.copyToClipboard(text)
                notes.append("Copied to clipboard")
            }

            if current.playSounds {
                NSSound(named: "Pop")?.play()
            }
            if current.showOverlay {
                let message = notes.isEmpty ? "Transcribed" : notes.joined(separator: " · ")
                overlay.show(.success(message: message), autoHideAfter: 1.6)
            } else {
                overlay.hide()
            }
        }
    }

    /// Re-checks permissions and engine availability, e.g. after a grant.
    public func recheck() {
        startMonitoringIfPossible()
        Task { await refreshInstallState(loadIfReady: true) }
    }
}
