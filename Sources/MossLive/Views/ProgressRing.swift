import SwiftUI

/// A ring that fills clockwise with progress, sized by its container.
///
/// Replaces the flat `ProgressView` bar wherever the number it shows is the
/// point of the screen (memory strength, subject mastery): a bar asks to be
/// read to the end, a ring reads whole at a glance and stays legible at the
/// 40pt a list row can afford.
///
/// Below 100 % the ring is an arc on a quiet track; at 100 % the track closes
/// and the accent moves to a checkmark, so "complete" is a shape change, not
/// a shade the student has to compare against a neighbour.
struct ProgressRing: View {
    /// 0...1. Values outside are clamped; NaN renders as empty.
    private let progress: Double
    private let lineWidth: CGFloat
    private let tint: Color
    private var showsCheckmark = true

    init(progress: Double, lineWidth: CGFloat = 4, tint: Color = Theme.accent, showsCheckmark: Bool = true) {
        self.progress = min(max(progress.isFinite ? progress : 0, 0), 1)
        self.lineWidth = lineWidth
        self.tint = tint
        self.showsCheckmark = showsCheckmark
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: progress)
            if progress >= 1, showsCheckmark {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .transition(.symbolEffect(.drawOn))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((progress * 100).rounded())) Prozent")
    }
}

#Preview {
    VStack(spacing: 40) {
        ProgressRing(progress: 0.34, lineWidth: 10)
            .frame(width: 120, height: 120)
        HStack(spacing: 24) {
            ProgressRing(progress: 0.0)
                .frame(width: 44, height: 44)
            ProgressRing(progress: 0.62)
                .frame(width: 44, height: 44)
            ProgressRing(progress: 1)
                .frame(width: 44, height: 44)
        }
    }
    .padding(40)
}
