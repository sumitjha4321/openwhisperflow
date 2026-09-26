import Foundation
import MoonshineKit
import WhisperKit

/// Reports whether an engine is ready, and loads it when asked.
public enum EngineLoader {
    /// Where Whisper's CoreML models are kept.
    ///
    /// WhisperKit otherwise defaults to `~/Documents/huggingface`, which is a
    /// surprising place to leave hundreds of megabytes.
    public static var whisperDownloadBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("OpenWhisperFlow/whisper", isDirectory: true)
    }

    private static func whisperFolder(variant: String) -> URL {
        // Layout that WhisperKit's hub download produces.
        whisperDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
    }

    public static func isInstalled(_ option: EngineOption) async -> Bool {
        switch option.backend {
        case .appleDictation:
            if #available(macOS 26, *) {
                return await AppleSpeechEngine.isInstalled(locale: AppleSpeechEngine.bestLocale())
            }
            return false

        case .whisper(let variant):
            let folder = whisperFolder(variant: variant)
            // A partial download leaves the folder behind, so require the
            // CoreML bundles rather than just the directory.
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
                return false
            }
            return contents.contains { $0.hasSuffix(".mlmodelc") }

        case .moonshine(let modelID):
            return ModelStore.shared.isInstalled(ModelCatalog.model(id: modelID))
        }
    }

    /// A downloaded model that no longer corresponds to anything in the catalog.
    ///
    /// These appear when the catalog changes — a model that used to be offered
    /// is dropped — and would otherwise sit on disk with no way to remove it
    /// from the interface.
    public struct OrphanedDownload: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let sizeMB: Int
        let url: URL
    }

    public static func orphanedDownloads() -> [OrphanedDownload] {
        var found: [OrphanedDownload] = []
        let manager = FileManager.default

        // Whisper: folders are named openai_whisper-<variant>.
        let wanted = Set(EngineCatalog.all.compactMap { option -> String? in
            guard case .whisper(let variant) = option.backend else { return nil }
            return variant
        })
        let whisperModels = whisperDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        for folder in (try? manager.contentsOfDirectory(at: whisperModels, includingPropertiesForKeys: nil)) ?? [] {
            let name = folder.lastPathComponent
            guard name.hasPrefix("openai_whisper-") || name.hasPrefix("distil-whisper") else { continue }
            let variant = name.replacingOccurrences(of: "openai_whisper-", with: "")
            guard !wanted.contains(variant) else { continue }
            found.append(OrphanedDownload(
                id: name,
                name: "Whisper \(variant)",
                sizeMB: directorySizeMB(folder),
                url: folder))
        }

        // Moonshine: one directory per model id.
        let moonshineIDs = Set(ModelCatalog.all.map(\.id))
        for folder in (try? manager.contentsOfDirectory(at: ModelStore.shared.root, includingPropertiesForKeys: nil)) ?? [] {
            let name = folder.lastPathComponent
            guard !moonshineIDs.contains(name) else { continue }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            found.append(OrphanedDownload(
                id: name,
                name: name.replacingOccurrences(of: "moonshine-", with: "Moonshine "),
                sizeMB: directorySizeMB(folder),
                url: folder))
        }

        return found.sorted { $0.sizeMB > $1.sizeMB }
    }

    public static func remove(_ orphan: OrphanedDownload) throws {
        try FileManager.default.removeItem(at: orphan.url)
    }

    private static func directorySizeMB(_ url: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var bytes = 0
        for case let item as URL in walker {
            bytes += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return bytes / 1_000_000
    }

    public static func removeDownload(_ option: EngineOption) throws {
        switch option.backend {
        case .appleDictation:
            break   // The OS owns these assets.
        case .whisper(let variant):
            try FileManager.default.removeItem(at: whisperFolder(variant: variant))
        case .moonshine(let modelID):
            try ModelStore.shared.remove(ModelCatalog.model(id: modelID))
        }
    }

    /// Downloads whatever is missing and returns a ready engine.
    public static func load(
        _ option: EngineOption,
        progress: @escaping @Sendable (EnginePreparation) -> Void
    ) async throws -> any TranscriptionEngine {
        guard option.isSupportedOnThisMac else {
            throw EngineError.unsupportedOnThisMac("\(option.name) needs a newer version of macOS.")
        }
        progress(.checking)

        switch option.backend {
        case .appleDictation:
            guard #available(macOS 26, *) else {
                throw EngineError.unsupportedOnThisMac("Apple Dictation needs macOS 26 or later.")
            }
            let locale = await AppleSpeechEngine.bestLocale()
            if await !AppleSpeechEngine.isInstalled(locale: locale) {
                progress(.downloading(fraction: nil, detail: "Asking macOS for its speech files…"))
                try await AppleSpeechEngine.ensureAssetsInstalled(locale: locale)
            }
            progress(.ready)
            return AppleSpeechEngine(locale: locale)

        case .whisper(let variant):
            let folder = whisperFolder(variant: variant)
            if await !isInstalled(option) {
                progress(.downloading(fraction: 0, detail: "Downloading \(option.name)"))
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: whisperDownloadBase,
                    progressCallback: { fraction in
                        progress(.downloading(
                            fraction: fraction.fractionCompleted,
                            detail: "Downloading \(option.name)"))
                    })
            }
            // Loading compiles the CoreML model on first use, which is slow
            // once and quick afterwards.
            progress(.loading(detail: "Preparing \(option.name)…"))
            let configuration = WhisperKitConfig(
                model: variant,
                downloadBase: whisperDownloadBase,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false)
            let pipeline = try await WhisperKit(configuration)
            progress(.ready)
            return WhisperEngine(
                pipeline: pipeline,
                englishOnly: variant.contains(".en"),
                name: option.name)

        case .moonshine(let modelID):
            let descriptor = ModelCatalog.model(id: modelID)
            let paths = try await ModelStore.shared.ensureAvailable(descriptor) { update in
                switch update {
                case .downloading(let fraction, let received, let total):
                    progress(.downloading(
                        fraction: fraction,
                        detail: "Downloading \(option.name) — \(received)/\(total) MB"))
                case .checking, .ready:
                    break
                case .failed(let message):
                    progress(.downloading(fraction: nil, detail: message))
                }
            }
            progress(.loading(detail: "Preparing \(option.name)…"))
            let model = try await Task.detached(priority: .userInitiated) {
                try MoonshineModel(paths: paths)
            }.value
            progress(.ready)
            return MoonshineEngine(model: model, name: option.name)
        }
    }
}
