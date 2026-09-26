import Foundation
import MoonshineKit

/// Moonshine through ONNX Runtime.
///
/// The model itself is synchronous and CPU-bound, so calls are funnelled onto a
/// dedicated queue and bridged to async.
final class MoonshineEngine: TranscriptionEngine {
    private let model: MoonshineModel
    private let queue = DispatchQueue(label: "app.openwhisperflow.moonshine", qos: .userInitiated)
    private let name: String

    init(model: MoonshineModel, name: String) {
        self.model = model
        self.name = name
    }

    var loadedDescription: String { "\(name) — \(model.description)" }

    func transcribe(samples: [Float]) async throws -> String {
        let model = self.model
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try model.transcribe(samples: samples))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
