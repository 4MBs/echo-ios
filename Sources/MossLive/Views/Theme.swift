import SwiftUI

/// The app uses the native iPadOS design language throughout: system colors,
/// SF Pro, grouped backgrounds and materials — no custom skin. This file only
/// keeps the few shared pieces the screens agree on.
enum Theme {
    /// Single accent token so every screen highlights the same way. Follows
    /// the app tint (system blue); recording state uses `.red` directly,
    /// matching the system convention.
    ///
    /// The accent means *interactive* and nothing else. A readiness bar, a
    /// subject dot or a status word never borrows it, or the one colour that
    /// promises a tap stops promising anything.
    static let accent = Color.accentColor

    /// Three radii, and a reason for each.
    ///
    /// The Lernen area had eight (26, 24, 22, 20, 16, 15, 14, 12), which is not
    /// a system but a habit — every new rectangle picked a number that looked
    /// right next to the last one. A control is small and sits inside things, a
    /// surface holds a group of rows, and the subject tile in Stunden is the one
    /// shape that is meant to read as a card rather than as a panel.
    enum Radius {
        static let control: CGFloat = 12
        static let surface: CGFloat = 18
        static let tile: CGFloat = 26
    }

    /// The 8pt grid, named after what it separates rather than after its size.
    enum Space {
        /// Screen margin on a phone-width column.
        static let screen: CGFloat = 20
        /// Screen margin once the window is wide enough to breathe.
        static let wideScreen: CGFloat = 24
        /// Between two sections of a screen.
        static let section: CGFloat = 28
        /// Between two rows inside a section.
        static let row: CGFloat = 12
        /// Inside a raised surface.
        static let inset: CGFloat = 16
    }

    /// Widths the layout changes its mind at — measured, never asked of a size
    /// class, because iPadOS windows resize freely.
    enum Width {
        /// A comfortable line length for a question.
        static let readable: CGFloat = 720
        /// One column of content in a detail panel.
        static let column: CGFloat = 700
        /// Where Heute splits into two columns.
        static let twoColumn: CGFloat = 1000
        /// Below this the layout is a Slide Over slice.
        static let narrow: CGFloat = 500
        /// Above this a question is set one step larger.
        static let largeQuestion: CGFloat = 900
    }

    /// Conversation metrics mirror T3 Code mobile's message hierarchy: a
    /// compact 85%-width user bubble, unboxed assistant prose, and 20pt turns.
    /// Keeping the values here makes the free chat, book assistant and study
    /// follow-up sheet feel like the same conversation component.
    enum Conversation {
        static let userBubbleRadius: CGFloat = 20
        static let userBubbleWidth: CGFloat = 0.85
        static let userHorizontalInset: CGFloat = 14
        static let userVerticalInset: CGFloat = 10
        static let turnSpacing: CGFloat = 20
    }
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

/// A tile that answers the finger: it dips a little while held, and comes back.
///
/// `.plain` leaves a card that size with no press state at all, which reads as a
/// tap that did not register. Shared by both grids, so a folder in Stunden and a
/// subject in Lernen behave the same under the same finger.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.22), value: configuration.isPressed)
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

    /// The single raised surface of the Lernen area: one radius, one colour, one
    /// name — so "how many surfaces does this screen have" is a question with an
    /// answer rather than a count of rectangles.
    func learnSurface() -> some View {
        cardSurface(cornerRadius: Theme.Radius.surface)
    }

    /// The canvas a study round runs on. Not the grouped background: a round is
    /// a mode, not a form, and the question has to be the brightest thing on the
    /// screen.
    func sessionScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
    }

    /// Floating chrome for a composer or another control that stays pinned over
    /// scrolling content. Liquid Glass is reserved for controls rather than
    /// content cards: the material responds to the page behind it while the
    /// shadow keeps the edge legible over text and images.
    func floatingComposerSurface(cornerRadius: CGFloat = 24) -> some View {
        glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}
