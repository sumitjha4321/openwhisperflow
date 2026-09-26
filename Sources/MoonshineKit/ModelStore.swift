import Foundation

/// Downloads models on demand and keeps them in Application Support.
///
/// Models are fetched rather than bundled so the app itself stays small and the
/// user can switch variants without a reinstall.
public final class ModelStore {
    public enum Progress: Sendable {
        case checking
        case downloading(fraction: Double, receivedMB: Int, totalMB: Int)
        case ready
        case failed(String)
    }

    public static let shared = ModelStore()

    public let root: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("OpenWhisperFlow/models", isDirectory: true)
    }

    public func directory(for model: ModelDescriptor) -> URL {
        root.appendingPathComponent(model.directoryName, isDirectory: true)
    }

    public func isInstalled(_ model: ModelDescriptor) -> Bool {
        let paths = MoonshineModelPaths(directory: directory(for: model))
        return (try? paths.validate()) != nil
    }

    public func installedSizeMB(_ model: ModelDescriptor) -> Int? {
        guard isInstalled(model) else { return nil }
        let directory = directory(for: model)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return bytes / 1_000_000
    }

    private func url(for path: String) -> URL {
        URL(string: "https://huggingface.co/\(ModelCatalog.repository)/resolve/main/\(path)")!
    }

    /// Ensures all three files are present, downloading whatever is missing.
    /// `progress` is called on an arbitrary queue.
    public func ensureAvailable(
        _ model: ModelDescriptor,
        progress: @escaping (Progress) -> Void
    ) async throws -> MoonshineModelPaths {
        let directory = directory(for: model)
        let paths = MoonshineModelPaths(directory: directory)

        progress(.checking)
        if isInstalled(model) {
            progress(.ready)
            return paths
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let jobs: [(remote: String, local: String)] = [
            (model.encoderPath, "encoder_model.onnx"),
            (model.decoderPath, "decoder_model_merged.onnx"),
            (model.tokenizerPath, "tokenizer.json"),
        ]

        // Progress is reported across the whole set so the UI shows one bar.
        let totalBytes = Int64(model.approximateMB) * 1_000_000
        var completedBytes: Int64 = 0

        for job in jobs {
            let destination = directory.appendingPathComponent(job.local)
            if FileManager.default.fileExists(atPath: destination.path) {
                continue
            }
            do {
                try await Downloader.download(from: url(for: job.remote), to: destination) { received in
                    let seen = completedBytes + received
                    let fraction = totalBytes > 0 ? min(0.999, Double(seen) / Double(totalBytes)) : 0
                    progress(.downloading(
                        fraction: fraction,
                        receivedMB: Int(seen / 1_000_000),
                        totalMB: model.approximateMB))
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                progress(.failed(error.localizedDescription))
                throw error
            }

            completedBytes += Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        try paths.validate()
        progress(.ready)
        return paths
    }

    public func remove(_ model: ModelDescriptor) throws {
        try FileManager.default.removeItem(at: directory(for: model))
    }
}

/// A single file download that reports progress and writes straight to disk.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: (Int64) -> Void
    private var session: URLSession?

    private init(onProgress: @escaping (Int64) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    static func download(from url: URL, to destination: URL, progress: @escaping (Int64) -> Void) async throws {
        let delegate = Downloader(onProgress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        defer { session.finishTasksAndInvalidate() }

        let temporary: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            continuation?.resume(throwing: NSError(domain: "OpenWhisperFlow", code: response.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "download failed (HTTP \(response.statusCode)) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "model file")",
            ]))
            continuation = nil
            return
        }
        // The delegate temp file is removed as soon as this method returns, so
        // it is moved somewhere durable before resuming.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("owf-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            continuation?.resume(returning: staged)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
