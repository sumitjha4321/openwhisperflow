import Foundation
import Testing
@testable import MoonshineKit

private let sampleRate: Double = 16_000

@Suite("Audio chunker")
struct AudioChunkerTests {
    @Test("Audio under the limit is left whole")
    func shortAudioIsNotSplit() {
        let samples = [Float](repeating: 0.1, count: Int(5 * sampleRate))
        let chunks = AudioChunker.split(samples: samples, sampleRate: sampleRate, maxChunkSeconds: 24)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == samples.count)
    }

    @Test("Long audio splits without losing a sample")
    func longAudioIsSplitLosslessly() {
        let samples = (0..<Int(70 * sampleRate)).map { Float(sin(Double($0) * 0.01)) }
        let chunks = AudioChunker.split(samples: samples, sampleRate: sampleRate, maxChunkSeconds: 24)

        #expect(chunks.count > 1, "70s should not stay in one chunk")
        #expect(chunks.reduce(0) { $0 + $1.count } == samples.count, "chunking must be lossless")
        for chunk in chunks {
            #expect(!chunk.isEmpty)
            #expect(Double(chunk.count) / sampleRate <= 24.001, "chunk exceeded the limit")
        }
    }

    @Test("The cut lands in a quiet gap rather than at the hard limit")
    func splitPrefersAQuietGap() {
        var samples = [Float](repeating: 0.5, count: Int(30 * sampleRate))
        let gapStart = Int(22 * sampleRate)
        let gapEnd = Int(23 * sampleRate)
        for index in gapStart..<gapEnd { samples[index] = 0 }

        let chunks = AudioChunker.split(samples: samples, sampleRate: sampleRate, maxChunkSeconds: 24)
        #expect(chunks.count == 2)

        let cut = chunks[0].count
        #expect(cut >= gapStart && cut <= gapEnd, "cut at \(cut) is outside the silent gap")
    }

    @Test("Empty input yields one empty chunk")
    func emptyInput() {
        let chunks = AudioChunker.split(samples: [], sampleRate: sampleRate, maxChunkSeconds: 24)
        #expect(chunks.count == 1)
        #expect(chunks[0].isEmpty)
    }

    @Test("RMS of silence is zero")
    func rmsOfSilence() {
        #expect(AudioChunker.rms([Float](repeating: 0, count: 100)[...]) == 0)
    }

    @Test("RMS of a constant signal is its level")
    func rmsOfConstant() {
        #expect(abs(AudioChunker.rms([Float](repeating: 0.5, count: 100)[...]) - 0.5) < 1e-6)
    }
}

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test("Only English models are listed")
    func englishOnly() {
        // The upstream repository also publishes tiny models for Arabic,
        // Japanese, Korean, Ukrainian, Vietnamese and Chinese; this app is
        // English-only, so none of them should be selectable.
        let otherLanguages = ["-ar", "-ja", "-ko", "-uk", "-vi", "-zh"]
        for model in ModelCatalog.all {
            for suffix in otherLanguages {
                #expect(!model.id.hasSuffix(suffix), "\(model.id) is not an English model")
            }
        }
        #expect(!ModelCatalog.all.isEmpty)
    }

    @Test("The default model is in the catalog")
    func defaultIsListed() {
        #expect(ModelCatalog.all.contains { $0.id == ModelCatalog.defaultModelID })
    }

    @Test("An unknown id falls back to a real model")
    func unknownIDFallsBack() {
        let model = ModelCatalog.model(id: "nope")
        #expect(ModelCatalog.all.contains(model))
    }
}

@Suite("WAV reader")
struct WAVReaderTests {
    /// Writes a 16-bit PCM WAV, optionally with an extra chunk before `data`, to
    /// prove the reader walks the chunk table rather than assuming a 44-byte header.
    private func writeWAV(sampleRate: Int, channels: Int, samples: [Int16], extraChunk: Bool) throws -> URL {
        var data = Data()
        func append32(_ value: Int) { for shift in [0, 8, 16, 24] { data.append(UInt8((value >> shift) & 0xFF)) } }
        func append16(_ value: Int) { for shift in [0, 8] { data.append(UInt8((value >> shift) & 0xFF)) } }

        let audioBytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + audioBytes)
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)                       // PCM
        append16(channels)
        append32(sampleRate)
        append32(sampleRate * channels * 2)
        append16(channels * 2)
        append16(16)

        if extraChunk {
            data.append(contentsOf: Array("LIST".utf8))
            append32(4)
            data.append(contentsOf: Array("INFO".utf8))
        }

        data.append(contentsOf: Array("data".utf8))
        append32(audioBytes)
        for sample in samples { append16(Int(sample) & 0xFFFF) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("owf-test-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    @Test("Reads mono 16 kHz PCM")
    func readsMono() throws {
        let samples: [Int16] = [0, 16384, -16384, 32767, -32768]
        let url = try writeWAV(sampleRate: 16_000, channels: 1, samples: samples, extraChunk: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let floats = try WAVReader.read16kHzMono(path: url.path)
        #expect(floats.count == samples.count)
        #expect(abs(floats[0]) < 1e-6)
        #expect(abs(floats[1] - 0.5) < 1e-4)
        #expect(abs(floats[2] + 0.5) < 1e-4)
    }

    @Test("Skips chunks it does not understand")
    func skipsUnknownChunks() throws {
        let samples = [Int16](repeating: 1000, count: 32)
        let url = try writeWAV(sampleRate: 16_000, channels: 1, samples: samples, extraChunk: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let floats = try WAVReader.read16kHzMono(path: url.path)
        #expect(floats.count == samples.count)
    }

    @Test("Downmixes stereo to mono")
    func downmixesStereo() throws {
        // Two frames: (1.0, 0.0) and (0.0, 1.0); both average to 0.5.
        let samples: [Int16] = [32767, 0, 0, 32767]
        let url = try writeWAV(sampleRate: 16_000, channels: 2, samples: samples, extraChunk: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let floats = try WAVReader.read16kHzMono(path: url.path)
        #expect(floats.count == 2)
        #expect(abs(floats[0] - 0.5) < 1e-3)
        #expect(abs(floats[1] - 0.5) < 1e-3)
    }

    @Test("Resamples other rates to 16 kHz")
    func resamples() throws {
        let samples = [Int16](repeating: 8000, count: 4_800)   // 0.1s at 48 kHz
        let url = try writeWAV(sampleRate: 48_000, channels: 1, samples: samples, extraChunk: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let floats = try WAVReader.read16kHzMono(path: url.path)
        #expect(abs(floats.count - 1_600) <= 2, "expected ~1600 samples, got \(floats.count)")
    }

    @Test("Rejects a file that is not a WAV")
    func rejectsNonWave() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("owf-test-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try WAVReader.read16kHzMono(path: url.path)
        }
    }
}

@Suite("Tokenizer decoder")
struct TokenizerDecoderTests {
    /// Builds a miniature tokenizer.json with the structure Moonshine uses: a
    /// `model.vocab` map, byte-fallback tokens, and added specials.
    private func writeTokenizer() throws -> URL {
        let payload: [String: Any] = [
            "added_tokens": [
                ["id": 0, "content": "<unk>", "special": true],
                ["id": 1, "content": "<s>", "special": true],
                ["id": 2, "content": "</s>", "special": true],
                ["id": 100, "content": "<<ST_0>>", "special": true],
            ],
            "model": [
                "type": "BPE",
                "vocab": [
                    "\u{2581}Hello": 10,      // ▁Hello
                    "\u{2581}world": 11,
                    ".": 12,
                    "\u{2581}caf": 13,
                    "<0xC3>": 20,             // byte-fallback pair for "é"
                    "<0xA9>": 21,
                ],
            ],
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("owf-tok-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return url
    }

    @Test("Turns ▁ into spaces and strips the leading one")
    func decodesWords() throws {
        let url = try writeTokenizer()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try TokenizerDecoder(tokenizerJSONPath: url.path)
        #expect(decoder.decode([10, 11, 12]) == "Hello world.")
    }

    @Test("Drops special tokens")
    func dropsSpecials() throws {
        let url = try writeTokenizer()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try TokenizerDecoder(tokenizerJSONPath: url.path)
        #expect(decoder.decode([1, 10, 11, 100, 2]) == "Hello world")
    }

    @Test("Fuses byte-fallback tokens into one character")
    func fusesByteFallback() throws {
        let url = try writeTokenizer()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try TokenizerDecoder(tokenizerJSONPath: url.path)
        // ▁caf + 0xC3 + 0xA9 -> "café"
        #expect(decoder.decode([13, 20, 21]) == "café")
    }

    @Test("Unknown ids are skipped")
    func skipsUnknownIDs() throws {
        let url = try writeTokenizer()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try TokenizerDecoder(tokenizerJSONPath: url.path)
        #expect(decoder.decode([10, 9_999, 11]) == "Hello world")
    }

    @Test("An empty id list decodes to an empty string")
    func decodesEmpty() throws {
        let url = try writeTokenizer()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try TokenizerDecoder(tokenizerJSONPath: url.path)
        #expect(decoder.decode([]).isEmpty)
    }

    @Test("A malformed tokenizer file is rejected")
    func rejectsMalformed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("owf-tok-bad-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try TokenizerDecoder(tokenizerJSONPath: url.path)
        }
    }
}
