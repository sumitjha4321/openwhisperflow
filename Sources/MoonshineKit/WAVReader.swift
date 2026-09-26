import Foundation

/// Minimal RIFF/WAVE reader for the command-line harness and for tests.
///
/// Handles 16-bit PCM and 32-bit float, mono or multi-channel, and walks the
/// chunk table properly rather than assuming a fixed 44-byte header (files
/// written by `say`, for instance, carry extra chunks).
public enum WAVReader {
    public static func read16kHzMono(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 12,
              data[0..<4].elementsEqual(Array("RIFF".utf8)),
              data[8..<12].elementsEqual(Array("WAVE".utf8)) else {
            throw MoonshineError.unexpectedModel("not a RIFF/WAVE file: \(path)")
        }

        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }

        var format = 1, channels = 1, rate = 16_000, bits = 16
        var audioRange: Range<Int>?
        var cursor = 12

        while cursor + 8 <= data.count {
            let id = String(decoding: data[cursor..<(cursor + 4)], as: UTF8.self)
            let size = u32(cursor + 4)
            let body = cursor + 8
            guard size >= 0, body + size <= data.count else { break }

            if id == "fmt " , size >= 16 {
                format = u16(body)
                channels = max(1, u16(body + 2))
                rate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                audioRange = body..<(body + size)
            }
            cursor = body + size + (size % 2)
        }

        guard let audioRange else {
            throw MoonshineError.unexpectedModel("no data chunk in \(path)")
        }
        let body = Data(data[audioRange])

        var interleaved: [Float]
        switch (format, bits) {
        case (1, 16):
            interleaved = body.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float($0) / 32_768.0 }
            }
        case (3, 32):
            interleaved = body.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
        case (1, 32):
            interleaved = body.withUnsafeBytes { raw in
                raw.bindMemory(to: Int32.self).map { Float($0) / 2_147_483_648.0 }
            }
        default:
            throw MoonshineError.unexpectedModel("unsupported WAV format \(format) with \(bits) bits")
        }

        var mono: [Float]
        if channels > 1 {
            let frames = interleaved.count / channels
            mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += interleaved[frame * channels + channel] }
                mono[frame] = sum / Float(channels)
            }
        } else {
            mono = interleaved
        }

        guard rate != 16_000 else { return mono }
        return resampleLinear(mono, from: Double(rate), to: 16_000)
    }

    static func resampleLinear(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard source > 0, !samples.isEmpty else { return samples }
        let ratio = target / source
        let count = max(1, Int(Double(samples.count) * ratio))
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let position = Double(index) / ratio
            let left = Int(position)
            let right = min(left + 1, samples.count - 1)
            let fraction = Float(position - Double(left))
            output[index] = samples[left] * (1 - fraction) + samples[right] * fraction
        }
        return output
    }
}
