import Foundation

/// A downloadable speech-to-text model.
public struct ModelDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String
    /// Approximate on-disk size, for the download prompt.
    public let approximateMB: Int
    let encoderPath: String
    let decoderPath: String
    let tokenizerPath: String

    public var directoryName: String { id }
}

/// The Moonshine variants published by moonshine-ai on Hugging Face.
///
/// English only: the repository also has single-language models for other
/// languages, but this app transcribes English.
///
/// Every variant shares one tokenizer, so the catalog points them all at the
/// same `tokenizer.json` rather than duplicating a 3.7 MB file per model.
public enum ModelCatalog {
    public static let repository = "moonshine-ai/moonshine"
    static let sharedTokenizer = "onnx/merged/base/float/tokenizer.json"

    public static let all: [ModelDescriptor] = [
        ModelDescriptor(
            id: "moonshine-base-quantized",
            displayName: "Moonshine Base (quantized)",
            detail: "Recommended. Best accuracy-to-size balance for English.",
            approximateMB: 63,
            encoderPath: "onnx/merged/base/quantized/encoder_model.onnx",
            decoderPath: "onnx/merged/base/quantized/decoder_model_merged.onnx",
            tokenizerPath: sharedTokenizer),
        ModelDescriptor(
            id: "moonshine-base-float",
            displayName: "Moonshine Base (float)",
            detail: "Full-precision base model. Slightly more accurate, ~4x larger.",
            approximateMB: 247,
            encoderPath: "onnx/merged/base/float/encoder_model.onnx",
            decoderPath: "onnx/merged/base/float/decoder_model_merged.onnx",
            tokenizerPath: sharedTokenizer),
        ModelDescriptor(
            id: "moonshine-tiny-quantized",
            displayName: "Moonshine Tiny (quantized)",
            detail: "Fastest and smallest. Noticeably weaker on proper nouns.",
            approximateMB: 28,
            encoderPath: "onnx/merged/tiny/quantized/encoder_model.onnx",
            decoderPath: "onnx/merged/tiny/quantized/decoder_model_merged.onnx",
            tokenizerPath: sharedTokenizer),
        ModelDescriptor(
            id: "moonshine-tiny-float",
            displayName: "Moonshine Tiny (float)",
            detail: "Full-precision tiny model.",
            approximateMB: 109,
            encoderPath: "onnx/merged/tiny/float/encoder_model.onnx",
            decoderPath: "onnx/merged/tiny/float/decoder_model_merged.onnx",
            tokenizerPath: sharedTokenizer),
    ]

    public static let defaultModelID = "moonshine-base-quantized"

    public static func model(id: String) -> ModelDescriptor {
        all.first { $0.id == id } ?? all[0]
    }
}
