import SwiftUI

/// Design tokens for the StudyFlow-style notebook look: near-black ink
/// sidebar, white paper with faint ruled lines, one locked indigo accent,
/// handwritten headers, butter-yellow sticky notes. Every color is dynamic so
/// hierarchy and contrast hold in dark mode (ink-tinted dark paper, lifted
/// indigo). No pure black; shadows are ink-tinted, never plain black.
enum Theme {
    /// Indigo, the single accent of the whole app. White labels on it pass
    /// WCAG AA in light mode; lifted on dark paper for parity.
    static let accent = Color(
        light: Color(red: 0.357, green: 0.357, blue: 0.839),
        dark: Color(red: 0.510, green: 0.510, blue: 0.920)
    )

    /// Sidebar background: near-black ink blue (same in both appearances).
    static let sidebar = Color(red: 0.051, green: 0.075, blue: 0.129)
    /// Selected sidebar row pill (the accent indigo).
    static let sidebarSelection = Color(red: 0.357, green: 0.357, blue: 0.839)

    /// Content-area "paper": just-off-white with a lavender hint.
    static let paper = Color(
        light: Color(red: 0.969, green: 0.969, blue: 0.984),
        dark: Color(red: 0.110, green: 0.114, blue: 0.157)
    )

    /// Card surface on top of the paper (never pure white).
    static let card = Color(
        light: Color(red: 0.998, green: 0.998, blue: 1.0),
        dark: Color(red: 0.160, green: 0.165, blue: 0.220)
    )

    /// Faint notebook ruled lines, cooled to match the ink.
    static let gridLine = Color(
        light: Color(red: 0.20, green: 0.20, blue: 0.45).opacity(0.055),
        dark: Color.white.opacity(0.05)
    )

    /// Tinted sticky-note surface (soft butter yellow).
    static let note = Color(
        light: Color(red: 0.965, green: 0.910, blue: 0.720),
        dark: Color(red: 0.290, green: 0.252, blue: 0.145)
    )

    /// Shadow base, tinted to the ink hue (apply opacity at the call site).
    static let shadow = Color(
        light: Color(red: 0.13, green: 0.13, blue: 0.32),
        dark: .black
    )

    /// Handwritten display font for headers and sticky notes (Noteworthy
    /// ships with iOS; no bundled font needed).
    static func handwriting(_ size: CGFloat) -> Font {
        .custom("Noteworthy-Bold", size: size)
    }
}

extension Color {
    /// Dynamic color from a light and a dark variant.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// Paper with faint horizontal ruled lines, used as the background of every
/// content screen (like a lined notebook page).
struct PaperBackground: View {
    var body: some View {
        Theme.paper
            .overlay(RuledLines(spacing: 30))
            .ignoresSafeArea()
    }
}

/// Horizontal notebook rules. Also used inside the live-transcript card so
/// the transcript reads like writing on a lined page.
struct RuledLines: View {
    var spacing: CGFloat = 30

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var posY = spacing
            while posY < size.height {
                lines.move(to: CGPoint(x: 0, y: posY))
                lines.addLine(to: CGPoint(x: size.width, y: posY))
                posY += spacing
            }
            context.stroke(lines, with: .color(Theme.gridLine), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Full-screen paper behind a screen's content. Expands first so the
    /// paper always fills the window, even when the content is tiny (a
    /// spinner, an empty state).
    func paperScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PaperBackground())
    }

    /// Soft white card sitting on the paper.
    func paperCard(cornerRadius: CGFloat = 16) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Theme.shadow.opacity(0.08), radius: 6, y: 2)
    }

    /// Slightly rotated sticky note with a piece of tape at the top and
    /// handwritten text, like in the mockup.
    func stickyNote(rotation: Double = -1.2) -> some View {
        font(Theme.handwriting(17))
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .background(Theme.note, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(0.22))
                    .frame(width: 56, height: 15)
                    .rotationEffect(.degrees(-3))
                    .offset(y: -7)
            }
            .shadow(color: Theme.shadow.opacity(0.16), radius: 5, y: 3)
            .rotationEffect(.degrees(rotation))
    }
}
