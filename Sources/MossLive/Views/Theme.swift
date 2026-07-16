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

    /// Content-area "paper": warm aged ivory, like an old notebook.
    static let paper = Color(
        light: Color(red: 0.949, green: 0.922, blue: 0.851),
        dark: Color(red: 0.125, green: 0.118, blue: 0.098)
    )

    /// Card surface on top of the paper: a fresher sheet, still warm.
    static let card = Color(
        light: Color(red: 0.980, green: 0.963, blue: 0.914),
        dark: Color(red: 0.180, green: 0.170, blue: 0.145)
    )

    /// Faint notebook ruled lines, sepia like faded print.
    static let gridLine = Color(
        light: Color(red: 0.45, green: 0.34, blue: 0.16).opacity(0.10),
        dark: Color.white.opacity(0.06)
    )

    /// The red margin line of a classic school notebook.
    static let marginLine = Color(
        light: Color(red: 0.75, green: 0.28, blue: 0.22).opacity(0.35),
        dark: Color(red: 0.85, green: 0.40, blue: 0.34).opacity(0.35)
    )

    /// Dark sepia writing ink (buttons, borders on paper).
    static let ink = Color(
        light: Color(red: 0.20, green: 0.16, blue: 0.12),
        dark: Color(red: 0.92, green: 0.89, blue: 0.83)
    )

    /// Tinted sticky-note surface (soft butter yellow).
    static let note = Color(
        light: Color(red: 0.965, green: 0.906, blue: 0.700),
        dark: Color(red: 0.290, green: 0.252, blue: 0.145)
    )

    /// Shadow base, tinted warm like the paper (apply opacity at call site).
    static let shadow = Color(
        light: Color(red: 0.30, green: 0.23, blue: 0.10),
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

/// Aged paper: warm ivory base, faint fiber speckles, ruled lines, and a
/// soft darkened edge (vignette) so it reads as an old notebook page rather
/// than a flat color. Used as the background of every content screen.
struct PaperBackground: View {
    var body: some View {
        Theme.paper
            .overlay(PaperGrain())
            .overlay(RuledLines(spacing: 30))
            .overlay(
                RadialGradient(
                    colors: [.clear, Theme.shadow.opacity(0.10)],
                    center: .center, startRadius: 260, endRadius: 1200
                )
            )
            .ignoresSafeArea()
    }
}

/// Deterministic fiber speckles that make the paper look like real stock.
struct PaperGrain: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func random() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
            }
            for _ in 0 ..< 420 {
                let rect = CGRect(
                    x: random() * size.width,
                    y: random() * size.height,
                    width: 0.8 + random() * 1.8,
                    height: 0.8 + random() * 1.2
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Theme.shadow.opacity(0.03 + random() * 0.05))
                )
            }
        }
        .allowsHitTesting(false)
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
