import Foundation
import SwiftUI
import ServiceManagement
import TranscriptionEngines
import DictationCore

/// Bindable wrapper over `PreferencesStore`, plus the bits of state the settings
/// window needs that are not user preferences (install sizes, key recording).
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet { PreferencesStore.shared.current = preferences }
    }
    @Published var isRecordingKey = false
    @Published var installedEngineIDs: Set<String> = []
    /// Downloads left behind by models no longer in the catalog.
    @Published var orphanedDownloads: [EngineLoader.OrphanedDownload] = []

    private var keyMonitor: Any?

    init() {
        preferences = PreferencesStore.shared.current
    }

    /// Which engines are downloaded. Checking is asynchronous, so the result is
    /// cached for the picker to read.
    func refreshInstalledEngines() async {
        var installed: Set<String> = []
        for option in EngineCatalog.selectable where await EngineLoader.isInstalled(option) {
            installed.insert(option.id)
        }
        installedEngineIDs = installed
        orphanedDownloads = EngineLoader.orphanedDownloads()
    }

    func removeOrphan(_ orphan: EngineLoader.OrphanedDownload) async {
        try? EngineLoader.remove(orphan)
        await refreshInstalledEngines()
    }

    var orphanedTotalMB: Int { orphanedDownloads.reduce(0) { $0 + $1.sizeMB } }

    // MARK: - Key recording

    /// Listens for the next key or modifier press and adopts it as the trigger.
    ///
    /// A local monitor is enough here because the settings window is focused
    /// while recording, and it avoids competing with the global event tap.
    func beginRecordingKey() {
        guard !isRecordingKey else { return }
        isRecordingKey = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {   // Escape cancels
                self.endRecordingKey()
                return nil
            }
            // For flagsChanged, only adopt the key as it goes down: the event
            // where its own flag bit is now set.
            if event.type == .flagsChanged {
                guard let mask = HotkeyTrigger.modifierMasks[event.keyCode],
                      UInt64(event.modifierFlags.rawValue) & mask == mask else { return nil }
            }

            self.preferences.trigger = HotkeyTrigger(
                keyCode: event.keyCode,
                label: HotkeyTrigger.label(forKeyCode: event.keyCode))
            self.endRecordingKey()
            return nil
        }
    }

    func endRecordingKey() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        isRecordingKey = false
    }

    // MARK: - Login item

    func applyLaunchAtLogin(_ enabled: Bool) {
        // Only meaningful for a real bundle; a bare executable has no service.
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("OpenWhisperFlow: could not update the login item: \(error)")
        }
    }
}
