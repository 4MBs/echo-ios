import SwiftUI

// Margin decorations like in the mockup: hand-drawn doodles ("Doodle Icons"
// by Khushmeen Sidhu, CC0, bundled via the MIT react-doodle-icons repack)
// plus handwritten hints. Always decorative: greyed out, never hit-testable.

extension Theme {
    /// Faded sepia ink for margin doodles and handwritten hints.
    static let doodle = Color(
        light: Color(red: 0.38, green: 0.31, blue: 0.22).opacity(0.50),
        dark: Color.white.opacity(0.30)
    )
}

/// One hand-drawn margin doodle from the asset catalog (template-tinted).
struct Doodle: View {
    let name: String
    var size: CGFloat = 70
    var rotation: Double = 0

    var body: some View {
        Image(name)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Theme.doodle)
            .rotationEffect(.degrees(rotation))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Right-hand margin column with doodles (mockup's Meine-Stunden margin).
/// Rendered only on wide layouts, so phones and narrow splits lose the
/// decoration, never the content.
struct MarginDoodles: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            VStack(spacing: 26) {
                Spacer()
                HandwrittenHint(
                    text: "Jede Stunde\nbringt dich\nweiter.",
                    arrow: "doodle-arrow-sw"
                )
                Doodle(name: "doodle-bag", size: 82, rotation: 6)
                Spacer()
            }
            .frame(width: 132)
            .padding(.trailing, 6)
        }
    }
}

/// A handwritten margin note ("Jede Stunde bringt dich weiter."), optionally
/// with a hand-drawn arrow underneath.
struct HandwrittenHint: View {
    let text: String
    var arrow: String?
    var rotation: Double = -3

    var body: some View {
        VStack(spacing: 6) {
            Text(text)
                .font(Theme.handwriting(16))
                .foregroundStyle(Theme.doodle)
                .multilineTextAlignment(.center)
            if let arrow {
                Doodle(name: arrow, size: 34)
            }
        }
        .rotationEffect(.degrees(rotation))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
