import AppKit
import SwiftUI
import Combine
import MoonshineKit
import DictationCore
import TranscriptionEngines

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController()
    private lazy var settingsModel = SettingsViewModel()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()
        buildStatusItem()
        controller.start()

        controller.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.render(status) }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: PreferencesStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyActivationPolicy() }
        }

        // `--settings` opens the settings window straight away, which is handy
        // when checking the UI without hunting for the menu bar item.
        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }

        Task { @MainActor in
            await firstRunIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsModel.endRecordingKey()
    }

    /// Launching the app while it is already running opens Preferences.
    ///
    /// This is the fallback when the menu bar icon cannot be reached — on a
    /// display with a notch and a full menu bar, macOS can place a status item
    /// behind the notch and simply not draw it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    /// Menu bar only by default: no Dock icon, and the app never becomes
    /// frontmost while dictating. A Dock icon can be turned on as a way back in
    /// when the menu bar is too crowded to show the status item.
    private func applyActivationPolicy() {
        let wantsDockIcon = PreferencesStore.shared.current.showDockIcon
        NSApp.setActivationPolicy(wantsDockIcon ? .regular : .accessory)
    }

    // MARK: - Status item

    /// Builds the menu bar item: an icon in the status area next to Wi-Fi and
    /// battery, with a two-entry menu.
    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.button?.toolTip = "OpenWhisperFlow"

        let menu = NSMenu()
        menu.addItem(withTitle: "Preferences…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OpenWhisperFlow", action: #selector(quit), keyEquivalent: "q")
            .target = self

        item.menu = menu
        statusItem = item
        render(.idle)

    }

    /// Reflects the current state in the icon. The menu itself stays at two
    /// entries, so the state is carried by the icon plus its tooltip.
    private func render(_ status: DictationController.Status) {
        guard let button = statusItem?.button else { return }
        button.toolTip = "OpenWhisperFlow — \(status.menuLabel)"

        let symbol: String
        switch status {
        case .recording: symbol = "mic.fill"
        case .transcribing: symbol = "ellipsis.circle"
        case .needsPermissions, .needsSetup, .failed: symbol = "exclamationmark.triangle"
        case .preparing: symbol = "arrow.down.circle"
        case .idle: symbol = "waveform"
        }

        guard let image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: status.menuLabel) else {
            // Should not happen on a supported OS, but an item with no image is
            // invisible in the menu bar, so fall back to text.
            button.image = nil
            button.title = "OWF"
            return
        }
        button.title = ""

        if case .recording = status {
            // Tinted red so an active recording is obvious at a glance. A
            // template image would be drawn in the menu bar's own colour.
            image.isTemplate = false
            button.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        } else {
            image.isTemplate = true
            button.image = image
        }
    }

    // MARK: - First run

    @MainActor
    private func firstRunIfNeeded() async {
        let needsSetup = await !EngineLoader.isInstalled(controller.selectedOption)

        if !Permissions.hasMicrophone {
            _ = await AudioRecorder.requestMicrophoneAccess()
        }
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
        if needsSetup || !Permissions.allGranted {
            openSettings()
        }
        controller.recheck()
    }

    // MARK: - Actions

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(model: settingsModel, controller: controller))

        // The window is given its size explicitly rather than inheriting the
        // hosting controller's, which lands at the layout minimum.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentViewController = hosting
        window.title = "OpenWhisperFlow"
        window.contentMinSize = NSSize(width: 540, height: 420)
        window.setContentSize(NSSize(width: 580, height: 640))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
}
