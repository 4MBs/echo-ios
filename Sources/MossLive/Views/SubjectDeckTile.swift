import SwiftUI
import UIKit

/// The disc cut into a deck card's top-right corner.
///
/// A circle centred on the corner itself, so the arc it leaves is convex toward
/// the middle of the card and the two edges it meets are cut square by the
/// card's own clip. Its radius is a fraction of the width rather than a count of
/// points, so the shape reads the same on a 200pt card in a multitasking slice
/// as on a 280pt one full screen.
struct CardCornerDisc: Shape {
    /// Radius as a fraction of the card's width.
    var scale: CGFloat = 0.46

    func path(in rect: CGRect) -> Path {
        let radius = rect.width * scale
        return Path(ellipseIn: CGRect(
            x: rect.maxX - radius,
            y: rect.minY - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}

/// The subject's colour, taken into the band white type can sit on.
///
/// `subjectStyle` picks its colours for a 29pt icon tile, where the colour is a
/// marker beside black text and full brightness is exactly right. Filling a
/// whole card with the same value and putting white on top is a different job:
/// white on system yellow is about 1.4:1, which nobody can read. So every card
/// fill is capped in brightness and floored in saturation. The hue is never
/// touched — Mathematik stays blue, Biologie stays green — which is the whole
/// reason this is a transform rather than a second palette to keep in step.
///
/// Grey is left alone: it has no hue worth preserving and no saturation to
/// raise, and raising it would turn Sonstige red.
func deckCardColor(_ color: Color, contrast: ColorSchemeContrast = .standard) -> Color {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    guard UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
        return color
    }
    let ceiling: CGFloat = contrast == .increased ? 0.56 : 0.74
    let minimum: CGFloat = saturation > 0.12 ? 0.52 : 0
    return Color(
        hue: Double(hue),
        saturation: Double(max(saturation, minimum)),
        brightness: Double(min(brightness, ceiling))
    )
}

/// One subject's deck as a card: its colour, its glyph, its name, and how much
/// of it is waiting.
///
/// Presentational on purpose. The tap target and the menu are layered over this
/// by whoever places it, because a menu nested inside a `NavigationLink`'s label
/// never reliably gets its own taps — the link takes them first.
struct SubjectDeckTile: View {
    let name: String
    let due: Int
    let total: Int
    let style: SubjectStyle

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .topLeading) {
            deckCardColor(style.color, contrast: contrast)
            CardCornerDisc()
                .fill(.black.opacity(0.22))
            label
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .aspectRatio(1.2, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(statusLabel)")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: style.outlineSymbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
                .frame(height: 30, alignment: .leading)
            Spacer(minLength: 12)
            Text(name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading)
            Text(statusLabel)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
        // Nothing here needs to clear the ellipsis: the glyph is on the far
        // side of the same row, and the name is at the other end of the card.
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A deck that has never been generated says so rather than showing a
    /// nought, and one with nothing due says how big it is rather than saying
    /// "0 fällig" — the number that matters is only interesting when it is not
    /// zero.
    private var statusLabel: String {
        guard total > 0 else { return "Keine Karten" }
        let cards = total == 1 ? "1 Karte" : "\(total) Karten"
        return due > 0 ? "\(due) fällig · \(cards)" : cards
    }
}

/// The ellipsis in a deck card's corner.
///
/// Laid over the card rather than built into it, so it is a sibling of the
/// navigation link and not a control inside its label. Sat on the darker corner
/// disc, where a white glyph has something to be white against.
struct DeckCardMenu<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Weitere Optionen")
    }
}

/// A card that answers the finger: it dips a little while held, and comes back.
///
/// `.plain` leaves a card with no press state at all, which on a tile this size
/// reads as a tap that did not register.
struct DeckCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.22), value: configuration.isPressed)
    }
}

#Preview {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)], spacing: 18) {
            ForEach(["Mathematik", "Erdkunde", "Biologie", "Chemie", "Sonstige"], id: \.self) { name in
                SubjectDeckTile(
                    name: name,
                    due: name == "Mathematik" ? 4 : 0,
                    total: name == "Chemie" ? 0 : 22,
                    style: subjectStyle(for: name)
                )
            }
        }
        .padding(24)
    }
    .groupedScreen()
}
