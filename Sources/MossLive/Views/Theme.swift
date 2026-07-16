import SwiftUI

/// Design tokens for the notebook look: deep forest-green sidebar, warm cream
/// "paper" content area with a faint grid, one locked honey-amber accent, soft
/// warm-white cards. Every color is dynamic so hierarchy and contrast hold in
/// dark mode (green-tinted dark paper, lifted amber). No pure black or white
/// anywhere; shadows are tinted to the paper's warmth, never plain black.
enum Theme {
    /// Honey amber, the single accent of the whole app. Deep in light mode so
    /// white button labels keep AA contrast; lifted on dark paper for parity.
    static let accent = Color(
        light: Color(red: 0.710, green: 0.440, blue: 0.120),
        dark: Color(red: 0.878, green: 0.620, blue: 0.290)
    )

    /// Sidebar background: deep forest green (same in both appearances).
    static let sidebar = Color(red: 0.086, green: 0.157, blue: 0.122)
    /// Selected sidebar row pill (moss green).
    static let sidebarSelection = Color(red: 0.180, green: 0.290, blue: 0.227)

    /// Content-area "paper": warm cream, green-tinted near-black in dark mode.
    static let paper = Color(
        light: Color(red: 0.969, green: 0.949, blue: 0.906),
        dark: Color(red: 0.114, green: 0.133, blue: 0.118)
    )

    /// Card surface on top of the paper (warm white, never pure white).
    static let card = Color(
        light: Color(red: 0.995, green: 0.988, blue: 0.972),
        dark: Color(red: 0.160, green: 0.186, blue: 0.166)
    )

    /// Faint notebook grid lines, warmed to match the paper.
    static let gridLine = Color(
        light: Color(red: 0.35, green: 0.28, blue: 0.12).opacity(0.07),
        dark: Color.white.opacity(0.05)
    )

    /// Tinted sticky-note surface (soft butter yellow).
    static let note = Color(
        light: Color(red: 0.965, green: 0.906, blue: 0.740),
        dark: Color(red: 0.290, green: 0.252, blue: 0.145)
    )

    /// Shadow base, tinted to the paper's hue (apply opacity at the call
    /// site). Pure-black shadows on warm paper read cold and generic.
    static let shadow = Color(
        light: Color(red: 0.32, green: 0.26, blue: 0.12),
        dark: .black
    )
}

extension Color {
    /// Dynamic color from a light and a dark variant.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// Cream paper with a faint square grid, used as the background of every
/// content screen.
struct PaperBackground: View {
    var body: some View {
        Theme.paper
            .overlay(
                Canvas { context, size in
                    let step: CGFloat = 26
                    var lines = Path()
                    var posX = step
                    while posX < size.width {
                        lines.move(to: CGPoint(x: posX, y: 0))
                        lines.addLine(to: CGPoint(x: posX, y: size.height))
                        posX += step
                    }
                    var posY = step
                    while posY < size.height {
                        lines.move(to: CGPoint(x: 0, y: posY))
                        lines.addLine(to: CGPoint(x: size.width, y: posY))
                        posY += step
                    }
                    context.stroke(lines, with: .color(Theme.gridLine), lineWidth: 1)
                }
            )
            .ignoresSafeArea()
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

    /// Soft warm-white card sitting on the paper.
    func paperCard(cornerRadius: CGFloat = 16) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Theme.shadow.opacity(0.10), radius: 6, y: 2)
    }

    /// Slightly rotated tinted card, like a sticky note taped onto the page.
    func stickyNote(rotation: Double = -1.2) -> some View {
        padding(14)
            .background(Theme.note, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: Theme.shadow.opacity(0.16), radius: 5, y: 3)
            .rotationEffect(.degrees(rotation))
    }
}
