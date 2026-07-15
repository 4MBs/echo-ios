import SwiftUI

/// Design tokens for the notebook look: navy sidebar, cream "paper" content
/// area with a faint grid, ink-purple accent, soft white cards. Every color is
/// dynamic so the app stays legible in dark mode (darker paper, same ink).
enum Theme {
    /// Ink purple — the single accent color of the whole app.
    static let accent = Color(red: 0.42, green: 0.40, blue: 0.86)

    /// Sidebar background (dark navy in both appearances).
    static let sidebarNavy = Color(red: 0.075, green: 0.09, blue: 0.17)
    /// Selected sidebar row pill.
    static let sidebarSelection = Color(red: 0.30, green: 0.30, blue: 0.55)

    /// Content-area "paper".
    static let paper = Color(
        light: Color(red: 0.972, green: 0.960, blue: 0.930),
        dark: Color(red: 0.090, green: 0.095, blue: 0.125)
    )

    /// Card surface on top of the paper.
    static let card = Color(
        light: .white,
        dark: Color(red: 0.145, green: 0.155, blue: 0.20)
    )

    /// Faint notebook grid lines.
    static let gridLine = Color(
        light: Color.black.opacity(0.045),
        dark: Color.white.opacity(0.05)
    )

    /// Tinted sticky-note surface (Schnellnotiz-style accent cards).
    static let note = Color(
        light: Color(red: 0.955, green: 0.915, blue: 0.78),
        dark: Color(red: 0.28, green: 0.25, blue: 0.16)
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
    /// Soft white card sitting on the paper.
    func paperCard(cornerRadius: CGFloat = 16) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// Slightly rotated tinted card, like a sticky note taped onto the page.
    func stickyNote(rotation: Double = -1.2) -> some View {
        padding(14)
            .background(Theme.note, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.10), radius: 5, y: 3)
            .rotationEffect(.degrees(rotation))
    }
}
