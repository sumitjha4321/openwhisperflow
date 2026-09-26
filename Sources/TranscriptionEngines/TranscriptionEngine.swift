import Foundation

/// A loaded speech-to-text engine.
///
/// Engines take 16 kHz mono audio in [-1, 1] — the format `AudioRecorder`
/// produces — and return plain text. Everything engine-specific (model files,
/// mel front ends, tokenizers, chunking) lives behind this.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Human-readable description of what actually got loaded, for diagnostics.
    var loadedDescription: String { get }

    func transcribe(samples: [Float]) async throws -> String
}

/// The audio format every engine expects. All three want 16 kHz mono, so the
/// recorder produces exactly this and no engine has to resample.
public enum AudioSpec {
    public static let sampleRate: Double = 16_000
}

public enum EngineError: Error, CustomStringConvertible {
    case unsupportedOnThisMac(String)
    case notInstalled(String)
    case failed(String)

    public var description: String {
        switch self {
        case .unsupportedOnThisMac(let m): return m
        case .notInstalled(let m): return m
        case .failed(let m): return m
        }
    }
}

/// Progress while an engine is being made ready.
public enum EnginePreparation: Sendable {
    case checking
    /// `fraction` is nil when the work is not measurable.
    case downloading(fraction: Double?, detail: String)
    case loading(detail: String)
    case ready
}
