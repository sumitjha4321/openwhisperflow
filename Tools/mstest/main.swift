import Foundation
import MoonshineKit

// Command-line harness: transcribes a 16 kHz mono WAV with the same code path
// the app uses. Useful for checking a model without granting any permissions.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("usage: mstest <model-directory> <audio.wav>")
    exit(2)
}

let modelDirectory = URL(fileURLWithPath: arguments[0])
let audioPath = arguments[1]

do {
    let started = Date()
    let model = try MoonshineModel(paths: MoonshineModelPaths(directory: modelDirectory))
    let loaded = -started.timeIntervalSinceNow
    print("loaded \(model.description) in \(String(format: "%.2f", loaded))s")

    let samples = try WAVReader.read16kHzMono(path: audioPath)
    let seconds = Double(samples.count) / MoonshineModel.sampleRate

    let transcribeStart = Date()
    let text = try model.transcribe(samples: samples)
    let elapsed = -transcribeStart.timeIntervalSinceNow

    print("audio: \(String(format: "%.2f", seconds))s  transcribe: \(String(format: "%.3f", elapsed))s  rtf: \(String(format: "%.4f", elapsed / seconds))")
    print("transcript: \(text)")
} catch {
    print("error: \(error)")
    exit(1)
}
