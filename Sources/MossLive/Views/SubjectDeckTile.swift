import SwiftUI

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

/// One subject's deck as a card: its colour, its glyph, its name, and how much
/// of it is waiting.
///
/// Presentational on purpose. The tap target and the menu are layered over this
/// by whoever places it, because a menu nested inside a `NavigationLink`'s label
/// never reliably gets its own taps — the link takes them first.
struct SubjectDeckTile: View {
    let name: String
    let due: Int
    let cardCount: Int
    /// How many recordings are filed under the subject. Nought means the card is
    /// drawn but does not open, and it says so by going grey.
    let lessonCount: Int
    let style: SubjectStyle

    @Environment(\.colorSchemeContrast) private var contrast

    private var isEmpty: Bool { lessonCount == 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            style.tint.cardFill(contrast: contrast)
            CardCornerDisc()
                .fill(.black.opacity(0.24))
            label
        }
        // Saturation, not opacity: a card faded against the page background
        // takes its white text down with it, and this one still has to be read.
        // Draining the colour greys the fill and leaves the contrast alone.
        .saturation(isEmpty ? 0.16 : 1)
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
            // Bold, and not dimmed much. Apple's contrast table asks 4.5:1 of
            // text at or below 17pt and only 3:1 of bold text at any size —
            // and 4.5:1 is not something white on a saturated fill reaches
            // without taking the fill so dark that the card stops being the
            // subject's colour.
            Text(statusLabel)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        // Nothing here needs to clear the ellipsis: the glyph is on the far
        // side of the same row, and the name is at the other end of the card.
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The most specific true thing there is room for. A subject with nothing in
    /// it says so; one with recordings but no decks counts the recordings; one
    /// with a deck counts the deck, and leads with what is due when something
    /// is — "0 fällig" is a number worth nobody's attention.
    private var statusLabel: String {
        if isEmpty { return "Keine Aufnahmen" }
        let cards = cardCount == 1 ? "1 Karte" : "\(cardCount) Karten"
        if due > 0 { return "\(due) fällig · \(cards)" }
        if cardCount > 0 { return cards }
        return lessonCount == 1 ? "1 Stunde" : "\(lessonCount) Stunden"
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
                // A glyph is mostly empty space, and empty space is not hit
                // tested. Without a shape only the three dots themselves would
                // take a tap; with it the whole 44pt target does.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Weitere Optionen")
    }
}

#Preview {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)], spacing: 18) {
            ForEach(["Mathematik", "Erdkunde", "Biologie", "Chemie", "Sonstige"], id: \.self) { name in
                SubjectDeckTile(
                    name: name,
                    due: name == "Mathematik" ? 4 : 0,
                    cardCount: name == "Chemie" ? 0 : 22,
                    lessonCount: name == "Erdkunde" ? 0 : 3,
                    style: subjectStyle(for: name)
                )
            }
        }
        .padding(24)
    }
    .groupedScreen()
}
