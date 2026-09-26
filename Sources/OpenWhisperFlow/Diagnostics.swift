import Foundation
import AppKit
import DictationCore
import MoonshineKit
import TranscriptionEngines

/// Prints what the app can see about its permissions and speech engine, then exits.
///
/// Run the binary *inside the bundle* — permissions are granted to the signed
/// app, so a copy under .build reports a different (untrusted) identity:
///
///     dist/OpenWhisperFlow.app/Contents/MacOS/OpenWhisperFlow --diagnose
enum Diagnostics {
    static func runAndExit() -> Never {
        // Engine checks are async; this waits for them before exiting.
        let finished = DispatchSemaphore(value: 0)
        Task {
            await report()
            finished.signal()
        }
        finished.wait()
        exit(0)
    }

    /// Transcribes a 16 kHz WAV with the currently selected engine, exercising
    /// the same path dictation uses. Lets an engine be checked without
    /// recording anything.
    static func transcribeAndExit(path: String) -> Never {
        let finished = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task {
            let option = EngineCatalog.option(id: PreferencesStore.shared.current.engineID)
            print("engine: \(option.name)")
            do {
                let samples = try WAVReader.read16kHzMono(path: path)
                let loadStarted = Date()
                let engine = try await EngineLoader.load(option) { update in
                    if case .downloading(let fraction, let detail) = update {
                        let percent = fraction.map { " \(Int($0 * 100))%" } ?? ""
                        print("  \(detail)\(percent)")
                    }
                }
                print("loaded in \(String(format: "%.2f", -loadStarted.timeIntervalSinceNow))s — \(engine.loadedDescription)")

                let started = Date()
                let text = try await engine.transcribe(samples: samples)
                let elapsed = -started.timeIntervalSinceNow
                let seconds = Double(samples.count) / AudioSpec.sampleRate
                print("audio: \(String(format: "%.2f", seconds))s  transcribe: \(String(format: "%.2f", elapsed))s  rtf: \(String(format: "%.3f", elapsed / seconds))")
                print("TRANSCRIPT: \(text)")
            } catch {
                print("error: \(error)")
                code = 1
            }
            finished.signal()
        }
        finished.wait()
        exit(code)
    }

    private static func report() async {
        let preferences = PreferencesStore.shared.current
        let option = EngineCatalog.option(id: preferences.engineID)

        func mark(_ ok: Bool) -> String { ok ? "yes" : "NO" }

        print("OpenWhisperFlow diagnostics")
        print("  bundle identifier   \(Bundle.main.bundleIdentifier ?? "(none — not running from a bundle)")")
        print("  macOS               \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("  accessibility       \(mark(Permissions.hasAccessibility))")
        print("  microphone          \(mark(Permissions.hasMicrophone))")
        print("  trigger key         \(preferences.trigger.label) (key code \(preferences.trigger.keyCode), modifier: \(mark(preferences.trigger.isModifier)))")
        print("  activation          \(preferences.activationMode.displayName)")
        print("  dock icon           \(mark(preferences.showDockIcon))")
        print()
        print("  engine              \(option.name)")
        print("  download            \(option.download)")
        print("  accuracy / speed    \(option.accuracy) / \(option.speed)")
        print("  set up              \(mark(await EngineLoader.isInstalled(option)))")

        do {
            let engine = try await EngineLoader.load(option) { _ in }
            print("  loads               yes — \(engine.loadedDescription)")
        } catch {
            print("  loads               NO — \(error)")
        }

        print()
        print("  other engines available on this Mac:")
        for other in EngineCatalog.selectable where other.id != option.id {
            let installed = await EngineLoader.isInstalled(other)
            print("    \(installed ? "•" : " ") \(other.name) — \(other.download), \(other.accuracy)")
        }

        let orphans = EngineLoader.orphanedDownloads()
        if !orphans.isEmpty {
            print()
            print("  unused downloads (removable in Preferences > Model):")
            for orphan in orphans {
                print("    \(orphan.name) — \(orphan.sizeMB) MB")
            }
        }

        if !Permissions.hasAccessibility {
            print("\nAccessibility is not granted. Enable OpenWhisperFlow under")
            print("System Settings > Privacy & Security > Accessibility.")
        }
    }
}
