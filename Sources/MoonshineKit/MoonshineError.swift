import Foundation

public enum MoonshineError: Error, CustomStringConvertible {
    case badTokenizer(String)
    case unexpectedModel(String)
    case missingFile(String)

    public var description: String {
        switch self {
        case .badTokenizer(let m): return "tokenizer: \(m)"
        case .unexpectedModel(let m): return "model: \(m)"
        case .missingFile(let p): return "missing file: \(p)"
        }
    }
}
