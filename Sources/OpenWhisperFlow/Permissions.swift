import Foundation
import AppKit
import AVFoundation
import ApplicationServices

/// The two system permissions this app needs, and how to ask for them.
///
/// Accessibility covers both halves of the flow: reading the trigger key
/// system-wide through an event tap, and posting the Command-V that inserts the
/// transcript. Microphone access is self-explanatory.
public enum Permissions {
    public static var hasAccessibility: Bool { AXIsProcessTrusted() }

    public static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static var allGranted: Bool { hasAccessibility && hasMicrophone }

    /// Shows the system's Accessibility prompt. macOS only presents it once per
    /// app version, so the settings window also offers a direct link.
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
