import AppKit

// Entry point. The app runs as a menu bar accessory, so there is no main window
// and no Dock icon; everything is driven by the global trigger key.

/// NSApplication holds its delegate weakly, so it is kept alive here.
private let appDelegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }

// A non-interactive self-check, useful when the trigger key or a permission is
// not behaving. Runs before any UI is created.
if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.runAndExit()
}

// `--transcribe <file.wav>` runs one file through the selected engine.
if let index = CommandLine.arguments.firstIndex(of: "--transcribe") {
    guard index + 1 < CommandLine.arguments.count else {
        print("usage: OpenWhisperFlow --transcribe <file.wav>")
        exit(2)
    }
    Diagnostics.transcribeAndExit(path: CommandLine.arguments[index + 1])
}

// Top-level code is not main-actor isolated, but it does run on the main
// thread, which is what `assumeIsolated` asserts.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
}
