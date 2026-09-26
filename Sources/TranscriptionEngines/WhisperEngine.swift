import Foundation
import WhisperKit

/// Whisper through CoreML, which puts the model on the Neural Engine.
///
/// WhisperKit supplies the mel front end, the tokenizer and the 30-second
/// windowing, so this only has to hand over audio and join the segments.
/// `WhisperKit` is not itself `Sendable`, but its `transcribe` is async and
/// safe to call from any task, and this wrapper only ever reads its reference.
final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    private let pipeline: WhisperKit
    private let options: DecodingOptions
    private let name: String

    init(pipeline: WhisperKit, englishOnly: Bool, name: String) {
        self.pipeline = pipeline
        self.name = name
        // Timestamps are suppressed because the transcript goes straight into a
        // text field. English-only variants are pinned to English so the model
        // does not spend a pass detecting the language.
        options = DecodingOptions(
            task: .transcribe,
            language: englishOnly ? "en" : nil,
            detectLanguage: !englishOnly,
            withoutTimestamps: true)
    }

    var loadedDescription: String { name }

    func transcribe(samples: [Float]) async throws -> String {
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        let text = results
            .map(\.text)
            .joined(separator: " ")
        return Self.tidy(text)
    }

    /// Whisper emits leading spaces and occasional bracketed non-speech tags.
    private static func tidy(_ text: String) -> String {
        var cleaned = text
        for tag in ["[BLANK_AUDIO]", "[NOISE]", "[MUSIC]", "(buzzing)", "[ Silence ]"] {
            cleaned = cleaned.replacingOccurrences(of: tag, with: " ")
        }
        return cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
