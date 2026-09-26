import SwiftUI

/// What the floating pill is currently saying.
enum OverlayState: Equatable {
    case hidden
    case recording(seconds: Double)
    case transcribing
    case success(message: String)
    case failure(message: String)
}

/// Observable backing for the overlay, updated from the dictation controller.
final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .hidden
    /// Recent input levels, newest last, used for the meter.
    @Published var levels: [Float] = Array(repeating: 0, count: 28)

    func push(level: Float) {
        var next = levels
        next.removeFirst()
        next.append(level)
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: 28)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 4)
        .fixedSize()
        .animation(.easeOut(duration: 0.18), value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()

        case .recording(let seconds):
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            LevelMeter(levels: model.levels)
                .frame(width: 96, height: 18)
            Text(Self.timeLabel(seconds))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

        case .transcribing:
            ProgressView()
                .controlSize(.small)
            Text("Transcribing…")
                .font(.system(size: 13, weight: .medium))

        case .success(let message):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium))

        case .failure(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: 320, alignment: .leading)
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Simple bar meter driven by recent microphone levels.
private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let width = max(1.5, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.primary.opacity(0.65))
                        .frame(
                            width: width,
                            height: max(2, geometry.size.height * CGFloat(level)))
                }
            }
            .frame(height: geometry.size.height, alignment: .center)
        }
    }
}
