import Foundation

/// Splits long recordings into encoder-sized pieces, preferring to cut where the
/// speaker is quietest so words are not sliced in half.
public enum AudioChunker {
    public static func split(samples: [Float], sampleRate: Double, maxChunkSeconds: Double) -> [[Float]] {
        let maxSamples = Int(maxChunkSeconds * sampleRate)
        guard samples.count > maxSamples else { return [samples] }

        // Look for the quietest moment in the last stretch of each chunk rather
        // than cutting at a hard boundary.
        let searchSamples = min(Int(4 * sampleRate), maxSamples / 3)
        let frame = Int(0.05 * sampleRate)

        var chunks: [[Float]] = []
        var start = 0
        while start < samples.count {
            let remaining = samples.count - start
            if remaining <= maxSamples {
                chunks.append(Array(samples[start..<samples.count]))
                break
            }

            let hardEnd = start + maxSamples
            let searchStart = max(start + frame, hardEnd - searchSamples)
            var quietestAt = hardEnd
            var quietestEnergy = Float.greatestFiniteMagnitude

            var position = searchStart
            while position + frame <= hardEnd {
                var energy: Float = 0
                for index in position..<(position + frame) { energy += samples[index] * samples[index] }
                if energy < quietestEnergy {
                    quietestEnergy = energy
                    quietestAt = position + frame / 2
                }
                position += frame
            }

            chunks.append(Array(samples[start..<quietestAt]))
            start = quietestAt
        }
        return chunks
    }

    /// Root-mean-square level, used for the recording meter and silence checks.
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
