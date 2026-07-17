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
