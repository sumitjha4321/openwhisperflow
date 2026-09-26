import Foundation
import AVFoundation
import Speech

/// macOS 26's built-in on-device transcriber.
///
/// This is the same recognition the system uses for dictation, so there is
/// nothing for the app to download — the OS manages the language assets. A
/// fresh analyzer is built per utterance, which keeps state simple and costs
/// little given how fast it runs.
@available(macOS 26, *)
final class AppleSpeechEngine: TranscriptionEngine {
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    var loadedDescription: String { "Apple Dictation (\(locale.identifier))" }

    /// Downloads the language assets if the system does not have them yet.
    static func ensureAssetsInstalled(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    static func isInstalled(locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { Self.matches($0, locale) }
    }

    /// Compares locales by language and region only.
    ///
    /// `Locale.current` can carry extensions — a region override shows up as
    /// `en_US@rg=inzzzz` — which never string-matches the plain `en_US` that
    /// `installedLocales` reports.
    static func matches(_ lhs: Locale, _ rhs: Locale) -> Bool {
        guard lhs.language.languageCode?.identifier == rhs.language.languageCode?.identifier else {
            return false
        }
        guard let left = lhs.region?.identifier, let right = rhs.region?.identifier else {
            return true
        }
        return left == right
    }

    /// Picks an English locale the system actually offers.
    ///
    /// The app transcribes English only, so this stays within English variants
    /// but still prefers the user's own region — `en_IN` and `en_GB` recognise
    /// their accents better than `en_US` does.
    static func bestLocale() async -> Locale {
        let english = await SpeechTranscriber.supportedLocales.filter {
            $0.language.languageCode?.identifier == "en"
        }
        let region = Locale.current.region?.identifier

        if let region, let match = english.first(where: { $0.region?.identifier == region }) {
            return match
        }
        return english.first { $0.region?.identifier == "US" }
            ?? english.first
            ?? Locale(identifier: "en-US")
    }

    func transcribe(samples: [Float]) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // SpeechAnalyzer traps outright if handed a format it does not accept,
        // so the audio is converted into the format it asks for.
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.failed("no audio format compatible with Apple Dictation")
        }
        let buffers = try Self.buffers(from: samples, target: target)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var pieces: [String] = []
            for try await result in transcriber.results {
                pieces.append(String(result.text.characters))
            }
            return pieces.joined()
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        for buffer in buffers {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts 16 kHz mono floats into the analyzer's format, in ~1s pieces.
    private static func buffers(from samples: [Float], target: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw EngineError.failed("could not describe the recorded audio format")
        }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw EngineError.failed("could not convert audio for Apple Dictation")
        }

        let chunk = 16_000
        var output: [AVAudioPCMBuffer] = []
        var offset = 0

        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)),
                  let channel = input.floatChannelData?[0] else {
                throw EngineError.failed("could not allocate an audio buffer")
            }
            samples.withUnsafeBufferPointer { raw in
                channel.update(from: raw.baseAddress! + offset, count: count)
            }
            input.frameLength = AVAudioFrameCount(count)

            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(count) * ratio) + 1_024
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw EngineError.failed("could not allocate a converted audio buffer")
            }

            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let error { throw EngineError.failed("audio conversion failed: \(error.localizedDescription)") }
            if converted.frameLength > 0 { output.append(converted) }
            offset += count
        }
        return output
    }
}
