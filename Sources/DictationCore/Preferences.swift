import Foundation

/// User preferences, persisted as JSON in Application Support.
public struct Preferences: Codable, Equatable {
    public var trigger: HotkeyTrigger = .fn
    public var activationMode: ActivationMode = .holdAndDoubleTap
    /// Which speech engine to use, as an `EngineCatalog` id. Empty means "use
    /// whatever the catalog recommends for this Mac", which is how a fresh
    /// install and an unrecognised value both behave.
    public var engineID: String = ""

    /// How long the key must be held before recording begins. Keeps an
    /// incidental tap of the Globe key from starting a recording.
    public var holdDelayMilliseconds: Int = 140
    /// Two taps inside this window count as a double-tap.
    public var doubleTapWindowMilliseconds: Int = 320
    /// Safety stop for a key that never reports its release.
    public var maximumRecordingSeconds: Int = 300

    public var copyToClipboard: Bool = true
    public var pasteIntoFocusedApp: Bool = true
    /// Put the previous clipboard contents back after pasting.
    public var restoreClipboardAfterPaste: Bool = false
    /// Consume the trigger key so the system does not also act on it.
    public var suppressTriggerKey: Bool = false

    /// Show a Dock icon as well as the menu bar item. Off by default, but a
    /// dependable way to reach the app when the menu bar has no room for the
    /// status item — macOS can place it behind the notch and not draw it.
    public var showDockIcon: Bool = false

    public var showOverlay: Bool = true
    public var playSounds: Bool = true
    public var launchAtLogin: Bool = false

    /// Every field has a default, but a public struct needs an explicit public
    /// initialiser for callers outside the module.
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case trigger, activationMode, engineID
        /// Pre-engine-picker name for this setting; read when migrating.
        case modelID
        case holdDelayMilliseconds, doubleTapWindowMilliseconds, maximumRecordingSeconds
        case copyToClipboard, pasteIntoFocusedApp, restoreClipboardAfterPaste, suppressTriggerKey
        case showDockIcon, showOverlay, playSounds, launchAtLogin
    }

    /// Decodes each field independently, falling back to its default.
    ///
    /// Swift's synthesised `Decodable` treats a missing key as an error and
    /// fails the whole decode, which would throw away every stored preference
    /// the first time a new field is added to this struct. Reading field by
    /// field keeps old settings files loadable, and tolerates a single
    /// corrupted value instead of discarding the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()

        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }

        trigger = read(.trigger, defaults.trigger)
        activationMode = read(.activationMode, defaults.activationMode)
        // Settings written before engines were selectable stored a Moonshine
        // model id under `modelID`. Those ids match their `EngineCatalog`
        // entries, so the old value carries over as-is.
        engineID = read(.engineID, read(.modelID, defaults.engineID))
        holdDelayMilliseconds = read(.holdDelayMilliseconds, defaults.holdDelayMilliseconds)
        doubleTapWindowMilliseconds = read(.doubleTapWindowMilliseconds, defaults.doubleTapWindowMilliseconds)
        maximumRecordingSeconds = read(.maximumRecordingSeconds, defaults.maximumRecordingSeconds)
        copyToClipboard = read(.copyToClipboard, defaults.copyToClipboard)
        pasteIntoFocusedApp = read(.pasteIntoFocusedApp, defaults.pasteIntoFocusedApp)
        restoreClipboardAfterPaste = read(.restoreClipboardAfterPaste, defaults.restoreClipboardAfterPaste)
        suppressTriggerKey = read(.suppressTriggerKey, defaults.suppressTriggerKey)
        showDockIcon = read(.showDockIcon, defaults.showDockIcon)
        showOverlay = read(.showOverlay, defaults.showOverlay)
        playSounds = read(.playSounds, defaults.playSounds)
        launchAtLogin = read(.launchAtLogin, defaults.launchAtLogin)
    }

    /// Written explicitly because `CodingKeys` carries a legacy `modelID` case
    /// that exists only for reading old files; it must not be written back.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(activationMode, forKey: .activationMode)
        try container.encode(engineID, forKey: .engineID)
        try container.encode(holdDelayMilliseconds, forKey: .holdDelayMilliseconds)
        try container.encode(doubleTapWindowMilliseconds, forKey: .doubleTapWindowMilliseconds)
        try container.encode(maximumRecordingSeconds, forKey: .maximumRecordingSeconds)
        try container.encode(copyToClipboard, forKey: .copyToClipboard)
        try container.encode(pasteIntoFocusedApp, forKey: .pasteIntoFocusedApp)
        try container.encode(restoreClipboardAfterPaste, forKey: .restoreClipboardAfterPaste)
        try container.encode(suppressTriggerKey, forKey: .suppressTriggerKey)
        try container.encode(showDockIcon, forKey: .showDockIcon)
        try container.encode(showOverlay, forKey: .showOverlay)
        try container.encode(playSounds, forKey: .playSounds)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
    }

    public var holdDelay: TimeInterval { Double(holdDelayMilliseconds) / 1000 }
    public var doubleTapWindow: TimeInterval { Double(doubleTapWindowMilliseconds) / 1000 }
}

/// Loads and saves `Preferences`, and notifies observers when they change.
public final class PreferencesStore {
    public static let shared = PreferencesStore()

    public static let didChange = Notification.Name("OpenWhisperFlowSettingsDidChange")

    private let url: URL
    private var cached: Preferences

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("OpenWhisperFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            cached = decoded
        } else {
            cached = Preferences()
        }
    }

    public var current: Preferences {
        get { cached }
        set {
            guard newValue != cached else { return }
            cached = newValue
            save()
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cached) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
