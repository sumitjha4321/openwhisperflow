import Foundation

/// Decodes Moonshine token ids back into text.
///
/// Moonshine uses a LLaMA-style SentencePiece BPE vocabulary. Turning ids into
/// text needs only the id→token table plus the tokenizer's decode pipeline —
/// `Replace(▁ → " ")`, `ByteFallback`, `Fuse`, `Strip(leading space)` — so the
/// merge table is not loaded at all.
public struct TokenizerDecoder {
    private let tokens: [Int32: String]
    private let byteValues: [Int32: UInt8]
    private let specialIDs: Set<Int32>

    public init(tokenizerJSONPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: tokenizerJSONPath))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MoonshineError.badTokenizer("tokenizer.json is not a JSON object")
        }
        guard let model = root["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Any] else {
            throw MoonshineError.badTokenizer("tokenizer.json has no model.vocab")
        }

        var tokens: [Int32: String] = [:]
        var byteValues: [Int32: UInt8] = [:]
        tokens.reserveCapacity(vocab.count)

        for (token, rawID) in vocab {
            guard let id = (rawID as? NSNumber)?.int32Value else { continue }
            tokens[id] = token
            if let byte = Self.byteFallbackValue(token) { byteValues[id] = byte }
        }

        // Added tokens (specials such as <s>, </s>, and the <<ST_n>> timestamps)
        // live outside model.vocab and are dropped when decoding.
        var specialIDs: Set<Int32> = []
        for entry in (root["added_tokens"] as? [[String: Any]] ?? []) {
            guard let id = (entry["id"] as? NSNumber)?.int32Value,
                  let content = entry["content"] as? String else { continue }
            tokens[id] = content
            if (entry["special"] as? NSNumber)?.boolValue == true { specialIDs.insert(id) }
        }

        self.tokens = tokens
        self.byteValues = byteValues
        self.specialIDs = specialIDs
    }

    /// Recognises the `<0x1F>`-style tokens that carry raw bytes.
    private static func byteFallbackValue(_ token: String) -> UInt8? {
        let scalars = Array(token.utf8)
        guard scalars.count == 6,
              scalars[0] == UInt8(ascii: "<"), scalars[1] == UInt8(ascii: "0"),
              scalars[2] == UInt8(ascii: "x"), scalars[5] == UInt8(ascii: ">"),
              let high = Self.hexValue(scalars[3]), let low = Self.hexValue(scalars[4]) else { return nil }
        return high << 4 | low
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    public func decode(_ ids: [Int32]) -> String {
        // Bytes are accumulated first so that byte-fallback tokens, which each
        // carry one byte of a multi-byte character, fuse correctly.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(ids.count * 4)

        for id in ids where !specialIDs.contains(id) {
            if let byte = byteValues[id] {
                bytes.append(byte)
            } else if let token = tokens[id] {
                for scalar in token.unicodeScalars {
                    if scalar == "\u{2581}" {
                        bytes.append(UInt8(ascii: " "))
                    } else {
                        bytes.append(contentsOf: Array(String(scalar).utf8))
                    }
                }
            }
        }

        let text = String(decoding: bytes, as: UTF8.self)
        return text.hasPrefix(" ") ? String(text.dropFirst()) : text
    }
}
