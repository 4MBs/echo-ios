import SwiftUI

/// The app uses the native iPadOS design language throughout: system colors,
/// SF Pro, grouped backgrounds and materials — no custom skin. This file only
/// keeps the few shared pieces the screens agree on.
enum Theme {
    /// Single accent token so every screen highlights the same way. Follows
    /// the app tint (system blue); recording state uses `.red` directly,
    /// matching the system convention.
    static let accent = Color.accentColor
}

/// The record control's colour. The control is built from a family of related
/// reds — five layers, three gradient stops, a highlight and the waveform — and a
/// tint rotates the whole family by the same amount, so they keep the
/// relationships to each other that the design depends on.
enum RecordTint: String, CaseIterable, Identifiable {
    case rot, orange, magenta, violett, blau, tuerkis, gruen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rot: "Rot"
        case .orange: "Orange"
        case .magenta: "Magenta"
        case .violett: "Violett"
        case .blau: "Blau"
        case .tuerkis: "Türkis"
        case .gruen: "Grün"
        }
    }

    /// How far around the wheel every colour in the control is turned.
    var shift: Double {
        switch self {
        case .rot: 0
        case .orange: 0.06
        case .magenta: 0.87
        case .violett: 0.75
        case .blau: 0.60
        case .tuerkis: 0.47
        case .gruen: 0.32
        }
    }

    /// The swatch: the control's own mid stop, turned by this tint.
    var swatch: Color {
        Color(hue: (0.0163 + shift).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 1)
    }

    static func nearest(to shift: Double) -> RecordTint {
        allCases.min { abs($0.shift - shift) < abs($1.shift - shift) } ?? .rot
    }
}

extension View {
    /// Standard grouped screen background (the Settings-style canvas).
    func groupedScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    /// A native inset-grouped card: the same surface a grouped List row uses.
    func cardSurface(cornerRadius: CGFloat = 16) -> some View {
        background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
