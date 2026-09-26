import Foundation
import COnnxRuntime

/// Locations of the three files a Moonshine model needs.
public struct MoonshineModelPaths: Sendable {
    public let encoder: String
    public let decoder: String
    public let tokenizer: String

    public init(encoder: String, decoder: String, tokenizer: String) {
        self.encoder = encoder
        self.decoder = decoder
        self.tokenizer = tokenizer
    }

    /// Layout produced by `ModelStore`: encoder_model.onnx, decoder_model_merged.onnx, tokenizer.json.
    public init(directory: URL) {
        encoder = directory.appendingPathComponent("encoder_model.onnx").path
        decoder = directory.appendingPathComponent("decoder_model_merged.onnx").path
        tokenizer = directory.appendingPathComponent("tokenizer.json").path
    }

    public func validate() throws {
        for path in [encoder, decoder, tokenizer] where !FileManager.default.fileExists(atPath: path) {
            throw MoonshineError.missingFile(path)
        }
    }
}

/// Moonshine speech-to-text over ONNX Runtime.
///
/// Moonshine consumes raw 16 kHz mono audio directly — there is no mel
/// spectrogram front end — and its encoder output length scales with the input,
/// so short utterances cost proportionally little.
///
/// Marked `@unchecked Sendable` because it holds ONNX Runtime session handles
/// that Swift cannot reason about. `transcribe` keeps all of its mutable state
/// in locals, so the type is safe to hand between queues, but callers are still
/// expected to confine a single instance to one queue at a time.
public final class MoonshineModel: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let encoder: ORTSession
    private let decoder: ORTSession
    private let tokenizer: TokenizerDecoder

    private let layerCount: Int
    private let headCount: Int64
    private let headDim: Int64

    private let startToken: Int32 = 1
    private let endToken: Int32 = 2

    /// Longest audio handed to the encoder in one piece. Moonshine's decoder has
    /// 194 position embeddings, so long recordings are split instead.
    private let maxChunkSeconds: Double = 24
    private let minimumSamples = 1_600

    public init(paths: MoonshineModelPaths) throws {
        try paths.validate()
        encoder = try ORTSession(modelPath: paths.encoder)
        decoder = try ORTSession(modelPath: paths.decoder)
        tokenizer = try TokenizerDecoder(tokenizerJSONPath: paths.tokenizer)

        layerCount = decoder.inputNames.reduce(into: 0) { count, name in
            if name.hasSuffix(".decoder.key"), name.hasPrefix("past_key_values.") { count += 1 }
        }
        guard layerCount > 0 else {
            throw MoonshineError.unexpectedModel("decoder exposes no past_key_values inputs")
        }

        // [batch, heads, past_len, head_dim] — heads and head_dim are static.
        let shape = try decoder.inputShape("past_key_values.0.decoder.key")
        guard shape.count == 4, shape[1] > 0, shape[3] > 0 else {
            throw MoonshineError.unexpectedModel("unexpected past_key_values shape \(shape)")
        }
        headCount = shape[1]
        headDim = shape[3]
    }

    public var description: String {
        "Moonshine(layers: \(layerCount), heads: \(headCount), headDim: \(headDim))"
    }

    // The graph names its cache tensors asymmetrically: inputs are
    // `past_key_values.0.decoder.key`, outputs are `present.0.decoder.key`.
    private func pastName(_ layer: Int, _ part: String) -> String {
        "past_key_values.\(layer).\(part)"
    }

    private func presentName(_ layer: Int, _ part: String) -> String {
        "present.\(layer).\(part)"
    }

    /// Transcribes 16 kHz mono float samples in [-1, 1].
    public func transcribe(samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        let chunks = AudioChunker.split(
            samples: samples,
            sampleRate: Self.sampleRate,
            maxChunkSeconds: maxChunkSeconds)

        var pieces: [String] = []
        for chunk in chunks {
            let text = try transcribeChunk(chunk).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(text) }
        }
        return pieces.joined(separator: " ")
    }

    private func transcribeChunk(_ samples: [Float]) throws -> String {
        var samples = samples
        if samples.count < minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minimumSamples - samples.count))
        }

        let audio = try ORTTensor.float(shape: [1, Int64(samples.count)]) { buffer in
            _ = buffer.initialize(fromContentsOf: samples)
        }
        let encoded = try encoder.run(
            inputs: [(name: "input_values", tensor: audio)],
            outputs: ["last_hidden_state"])
        guard let hidden = encoded["last_hidden_state"] else {
            throw ORTError.missingOutput("last_hidden_state")
        }

        // Self-attention cache starts empty and grows one position per step.
        var selfCache: [String: ORTTensor] = [:]
        let empty = try ORTTensor.zeros(shape: [1, headCount, 0, headDim])
        for layer in 0..<layerCount {
            selfCache[pastName(layer, "decoder.key")] = empty
            selfCache[pastName(layer, "decoder.value")] = empty
        }
        // Cross-attention cache is only computed on the no-cache branch (the
        // first step). Later steps return empty placeholders for it, so it is
        // captured once and then reused unchanged for the rest of the decode.
        var crossCache: [String: ORTTensor] = [:]
        for layer in 0..<layerCount {
            crossCache[pastName(layer, "encoder.key")] = empty
            crossCache[pastName(layer, "encoder.value")] = empty
        }

        var requestedOutputs = ["logits"]
        for layer in 0..<layerCount {
            requestedOutputs.append(presentName(layer, "decoder.key"))
            requestedOutputs.append(presentName(layer, "decoder.value"))
            requestedOutputs.append(presentName(layer, "encoder.key"))
            requestedOutputs.append(presentName(layer, "encoder.value"))
        }

        let seconds = Double(samples.count) / Self.sampleRate
        // Moonshine emits roughly 6 tokens per second of speech; the cap keeps a
        // degenerate repeat loop from running to the position-embedding limit.
        let maxTokens = max(8, min(Int(seconds * 6) + 8, 190))

        var tokens: [Int32] = []
        var previous = startToken
        var usingCache = false

        for _ in 0..<maxTokens {
            var inputs: [(name: String, tensor: ORTTensor)] = [
                (name: "input_ids", tensor: try ORTTensor.int64(shape: [1, 1], values: [Int64(previous)])),
                (name: "encoder_hidden_states", tensor: hidden),
                (name: "use_cache_branch", tensor: try ORTTensor.bool(usingCache)),
            ]
            for (name, tensor) in selfCache { inputs.append((name: name, tensor: tensor)) }
            for (name, tensor) in crossCache { inputs.append((name: name, tensor: tensor)) }

            let outputs = try decoder.run(inputs: inputs, outputs: requestedOutputs)
            guard let logits = outputs["logits"] else { throw ORTError.missingOutput("logits") }

            let next = try logits.withFloats { buffer -> Int32 in
                // [1, 1, vocab] — greedy pick over the final position.
                let vocab = buffer.count
                var best = 0
                var bestScore = -Float.greatestFiniteMagnitude
                for index in 0..<vocab where buffer[index] > bestScore {
                    bestScore = buffer[index]
                    best = index
                }
                return Int32(best)
            }
            if next == endToken { break }
            tokens.append(next)
            previous = next

            for layer in 0..<layerCount {
                for part in ["decoder.key", "decoder.value"] {
                    if let tensor = outputs[presentName(layer, part)] {
                        selfCache[pastName(layer, part)] = tensor
                    }
                }
            }
            if !usingCache {
                for layer in 0..<layerCount {
                    for part in ["encoder.key", "encoder.value"] {
                        if let tensor = outputs[presentName(layer, part)] {
                            crossCache[pastName(layer, part)] = tensor
                        }
                    }
                }
                usingCache = true
            }
        }

        return tokenizer.decode(tokens)
    }
}
