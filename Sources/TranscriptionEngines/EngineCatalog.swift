import Foundation
import MoonshineKit

/// One choice in the model picker.
///
/// The copy here is deliberately plain: people choosing a speech model care
/// about how big the download is and how accurate the result will be, not about
/// parameter counts or quantisation.
///
/// Every option transcribes English. Multilingual models are deliberately left
/// out: they are larger and slightly weaker on English than an English-only
/// model of the same size.
public struct EngineOption: Identifiable, Hashable, Sendable {
    public enum Backend: Hashable, Sendable {
        /// macOS 26's built-in on-device transcriber.
        case appleDictation
        /// Whisper through CoreML; the string is a WhisperKit variant name.
        case whisper(variant: String)
        /// Moonshine through ONNX Runtime; the string is a `ModelCatalog` id.
        case moonshine(modelID: String)
    }

    public let id: String
    public let name: String
    /// What the user has to download, e.g. "No download" or "480 MB".
    public let download: String
    /// Plain accuracy wording: "Basic", "Good", "Very good", "Best".
    public let accuracy: String
    public let speed: String
    /// One sentence, no jargon.
    public let summary: String
    public let backend: Backend
    /// Set when the option needs a newer macOS than the app's minimum.
    public let requiresMacOS26: Bool

    public var isSupportedOnThisMac: Bool {
        guard requiresMacOS26 else { return true }
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Roughly how much disk the download needs, for ordering and warnings.
    public var approximateMB: Int {
        switch backend {
        case .appleDictation: return 0
        case .whisper(let variant): return EngineCatalog.whisperSizeMB[variant] ?? 500
        case .moonshine(let id): return ModelCatalog.model(id: id).approximateMB
        }
    }
}

public enum EngineCatalog {
    static let whisperSizeMB: [String: Int] = [
        "base.en": 145,
        "small.en": 480,
    ]

    /// Ordered best-first, so the most accurate option is what people see.
    public static let all: [EngineOption] = [
        EngineOption(
            id: "apple-dictation",
            name: "Apple Dictation (built in)",
            download: "No download",
            accuracy: "Best",
            speed: "Instant",
            summary: "Uses the English speech recognition built into macOS. Nothing to download, and the most accurate option in our testing. Needs macOS 26 or later.",
            backend: .appleDictation,
            requiresMacOS26: true),

        EngineOption(
            id: "whisper-small-en",
            name: "Whisper Small",
            download: "480 MB",
            accuracy: "Best",
            speed: "Fast",
            summary: "A large download, but very accurate. The best choice if you want everything to work offline, and it runs on older macOS too.",
            backend: .whisper(variant: "small.en"),
            requiresMacOS26: false),

        EngineOption(
            id: "whisper-base-en",
            name: "Whisper Base",
            download: "145 MB",
            accuracy: "Very good",
            speed: "Fast",
            summary: "A middle ground: a moderate download with accuracy well above the small models.",
            backend: .whisper(variant: "base.en"),
            requiresMacOS26: false),

        EngineOption(
            id: "moonshine-base-quantized",
            name: "Moonshine Base",
            download: "63 MB",
            accuracy: "Good",
            speed: "Very fast",
            summary: "Small and very quick, but makes noticeably more mistakes with names and technical words.",
            backend: .moonshine(modelID: "moonshine-base-quantized"),
            requiresMacOS26: false),

        EngineOption(
            id: "moonshine-tiny-quantized",
            name: "Moonshine Tiny",
            download: "28 MB",
            accuracy: "Basic",
            speed: "Very fast",
            summary: "The smallest and fastest option. Fine for short, clear phrases; expect more mistakes otherwise.",
            backend: .moonshine(modelID: "moonshine-tiny-quantized"),
            requiresMacOS26: false),
    ]

    /// The option to start new installs on: Apple's engine where the OS has it,
    /// otherwise the best offline model that is not a huge download.
    public static var defaultEngineID: String {
        if #available(macOS 26, *) { return "apple-dictation" }
        return "whisper-base-en"
    }

    public static func option(id: String) -> EngineOption {
        if let match = all.first(where: { $0.id == id }), match.isSupportedOnThisMac {
            return match
        }
        // An unknown id, or one this Mac cannot run (a preferences file copied
        // from a newer macOS, say), falls back rather than failing to start.
        if let match = all.first(where: { $0.id == id }), !match.isSupportedOnThisMac {
            return option(id: defaultEngineID)
        }
        return all.first { $0.id == defaultEngineID } ?? all[all.count - 2]
    }

    public static var selectable: [EngineOption] {
        all.filter(\.isSupportedOnThisMac)
    }
}
