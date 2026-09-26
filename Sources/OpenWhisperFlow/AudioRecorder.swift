import Foundation
import AVFoundation
import MoonshineKit
import DictationCore

/// Captures microphone audio as 16 kHz mono floats, the format Moonshine wants.
///
/// The engine is started the moment the trigger key goes down — before the hold
/// delay has decided whether this is a real dictation — and audio is buffered
/// from that instant. When recording is confirmed, a short pre-roll is kept so
/// a word spoken as the key went down is not clipped. If the press turns out to
/// be a stray tap, the buffer is thrown away and the microphone is released.
public final class AudioRecorder {
    public enum RecorderError: Error, CustomStringConvertible {
        case engineUnavailable(String)

        public var description: String {
            switch self {
            case .engineUnavailable(let m): return "microphone: \(m)"
            }
        }
    }

    /// Audio kept from before recording was confirmed.
    private let preRoll: TimeInterval = 0.3

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: MoonshineModel.sampleRate,
        channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private var confirmed = false

    /// Latest input level in 0...1, delivered on the main queue while recording.
    public var onLevel: ((Float) -> Void)?

    public init() {}

    public var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return capturing
    }

    /// Opens the microphone and starts buffering. Safe to call repeatedly.
    public func warmUp() throws {
        lock.lock()
        if capturing { lock.unlock(); return }
        samples.removeAll(keepingCapacity: true)
        capturing = true
        confirmed = false
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            lock.lock(); capturing = false; lock.unlock()
            throw RecorderError.engineUnavailable("no usable input device")
        }

        // A fresh converter per session keeps resampler state from leaking
        // between recordings.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            lock.lock(); capturing = false; lock.unlock()
            throw RecorderError.engineUnavailable("cannot convert \(inputFormat.sampleRate) Hz input to 16 kHz")
        }
        self.converter = converter

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter, from: inputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); capturing = false; lock.unlock()
            throw RecorderError.engineUnavailable(error.localizedDescription)
        }
    }

    /// Marks the point where the user really began dictating.
    public func confirm() {
        lock.lock()
        defer { lock.unlock() }
        guard capturing, !confirmed else { return }
        confirmed = true
        let keep = Int(preRoll * MoonshineModel.sampleRate)
        if samples.count > keep {
            samples.removeFirst(samples.count - keep)
        }
    }

    /// Stops capture and returns everything recorded since `confirm()`.
    public func finish() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        converter = nil

        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        capturing = false
        confirmed = false
        return captured
    }

    /// Stops capture and discards the audio.
    public func cancel() {
        _ = finish()
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, from inputFormat: AVAudioFormat) {
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return }

        let frames = Int(output.frameLength)
        let incoming = UnsafeBufferPointer(start: channel, count: frames)
        let level = AudioChunker.rms(ArraySlice(incoming))

        lock.lock()
        if capturing {
            samples.append(contentsOf: incoming)
            // Before confirmation only the pre-roll window is worth keeping.
            if !confirmed {
                let keep = Int(preRoll * MoonshineModel.sampleRate)
                if samples.count > keep { samples.removeFirst(samples.count - keep) }
            }
        }
        let active = capturing
        lock.unlock()

        if active, let onLevel {
            // Perceptual-ish scaling so quiet speech still moves the meter.
            let scaled = min(1, max(0, (level * 12).squareRoot()))
            DispatchQueue.main.async { onLevel(scaled) }
        }
    }

    /// Duration of the audio captured so far, in seconds.
    public var capturedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / MoonshineModel.sampleRate
    }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
