import SwiftUI

// The small parts every Lernen screen is built from. Rows, not cards: a screen
// where every line is its own rectangle has no rhythm, and a screen without
// rhythm has no hierarchy.

/// A section heading. One weight, one size, everywhere in the area.
struct LearnSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A subject as the app already draws it everywhere else: its colour, its
/// glyph, in a rounded square.
///
/// Echo owns a genuine identity system — twenty-four subjects, each with a
/// published colour and a Phosphor glyph, used by the Stunden grid since the
/// beginning. The Lernen area was spending it on a ten-point dot, which made
/// every row grey and made this tab look like it belonged to a different app.
/// The glyph carries the scrim the card colours were designed with, so white on
/// Englisch-yellow is as legible here as it is on a folder.
struct SubjectGlyph: View {
    let subject: String?
    var size: CGFloat = 34

    @Environment(\.colorSchemeContrast) private var contrast
    /// The glyph tracks Dynamic Type: an asset image has no font to scale with.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let style = subjectStyle(for: subject)
        let side = size * scale
        return ZStack {
            style.tint.color
            // Only the yellows and light greens need it; for most of the wheel
            // both ends of the scrim are zero and this layer is not there.
            Color.black.opacity(style.tint.scrim(contrast: contrast).bottom * 0.7)
            Image(style.icon)
                .resizable()
                .scaledToFit()
                .frame(width: side * 0.56, height: side * 0.56)
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        // Proportional, not one of the three surface radii: this is a glyph
        // tile that grows with Dynamic Type, and it keeps the ratio the system
        // uses for the same shape in Settings (7pt on 29pt).
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// What today's round is made of, as one bar.
///
/// Each subject gets a segment as wide as its share of the cards. It is not a
/// chart to read values off — the rows underneath are the legend and carry the
/// numbers — it is the shape of the round, so "three subjects, mostly Mathe" is
/// answered before any row is read.
struct PlanCompositionBar: View {
    let blocks: [StudyPlan.Block]
    var height: CGFloat = 8

    private var total: Int { max(1, blocks.reduce(0) { $0 + $1.cardCount }) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(blocks) { block in
                    Capsule()
                        .fill(subjectStyle(for: block.subject).tint.color)
                        .frame(width: max(4, geo.size.width * Double(block.cardCount) / Double(total) - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Right and wrong as one proportion, with both numbers written out.
///
/// The only place the Lernen area uses green and red, and never without the
/// words beside it.
struct OutcomeBar: View {
    let correct: Int
    let wrong: Int
    var height: CGFloat = 10

    private var total: Int { max(1, correct + wrong) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if correct > 0 {
                        Capsule().fill(Color.green)
                            .frame(width: max(6, geo.size.width * Double(correct) / Double(total) - 1))
                    }
                    if wrong > 0 {
                        Capsule().fill(Color.red)
                            .frame(width: max(6, geo.size.width * Double(wrong) / Double(total) - 1))
                    }
                }
            }
            .frame(height: height)

            HStack(spacing: Theme.Space.inset) {
                legend(symbol: "checkmark.circle.fill", tint: .green, count: correct, word: "richtig")
                if wrong > 0 {
                    legend(symbol: "xmark.circle.fill", tint: .red, count: wrong, word: "offen")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(correct) richtig, \(wrong) offen")
    }

    private func legend(symbol: String, tint: Color, count: Int, word: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(tint)
            Text("\(count) \(word)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// How solid something is: a bar and a word, never a percentage and never a
/// colour on its own.
struct ReadinessBar: View {
    let value: Double
    let subject: String?
    /// How wide the bar itself is allowed to be.
    var width: CGFloat = 72

    private var readiness: Readiness { Readiness(value) }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(subjectStyle(for: subject).tint.color)
                    .frame(width: max(0, min(1, value)) * width)
            }
            .frame(width: width, height: 4)
            Text(readiness.word)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bereitschaft: \(readiness.word)")
    }
}

/// A row inside a grouped surface: content, a hairline under it unless it is the
/// last one.
///
/// Rows share one surface per section rather than each carrying its own. Ten
/// cards down a page is ten shadows and nine gaps between things that belong
/// together; one surface with rules in it is a list, which is what these are.
struct LearnRowGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .learnSurface()
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous))
    }
}

/// The hairline between two rows, inset to where the text starts.
struct LearnRowDivider: View {
    var body: some View {
        Divider().padding(.leading, Theme.Space.inset)
    }
}

/// A row that answers the finger without moving: a full-width tile that shrank
/// would pull away from the hairlines it sits between.
struct LearnRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.06 : 0))
            .contentShape(Rectangle())
            // A trackpad or a Magic Mouse gets the same answer the finger does,
            // which on an iPad with a keyboard case is most of the time.
            .hoverEffect(.highlight)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// The one filled button a Lernen screen is allowed to have.
///
/// Sized to its label rather than stretched across the column. The guidelines
/// are explicit about it — *"Avoid full-width buttons. Buttons feel at home in
/// iOS when they respect system-defined margins and are inset from the edges of
/// the screen"* — and a 700pt blue slab reads as a web call to action rather
/// than as an iPad control. It only fills the width where there is no width to
/// spare: in a Slide Over slice, or when the type is large enough that the
/// label would otherwise wrap inside a small pill.
///
/// Words, no glyph: it is already the most prominent thing on the screen, and a
/// symbol on it would be decoration.
struct LearnPrimaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    private var fillsWidth: Bool { typeSize >= .accessibility1 }

    var body: some View {
        // Spelled out rather than written inline in the frame: `maxWidth` takes
        // an optional, and a bare-literal ternary flowing into one is the kind
        // of inference this codebase has been bitten by before.
        let maxWidth: CGFloat? = fillsWidth ? .infinity : nil
        return Button(action: action) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, fillsWidth ? 0 : 10)
                .frame(maxWidth: maxWidth)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }
}

/// The shape of the screen while the very first load runs and there is nothing
/// stored to show instead.
///
/// Not a spinner in the middle of an empty page: the shape of the answer is
/// already known — a block with a count in it and a list under it — so the
/// placeholder is that shape, and the content lands in place instead of
/// replacing something unrelated.
struct LearnSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            VStack(alignment: .leading, spacing: Theme.Space.row) {
                bar(width: 140, height: 12)
                bar(width: 200, height: 30)
                bar(width: 260, height: 14)
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 170, height: 44)
                    .padding(.top, 4)
            }
            .padding(Theme.Space.inset + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .learnSurface()

            VStack(alignment: .leading, spacing: Theme.Space.row) {
                bar(width: 110, height: 14)
                LearnRowGroup {
                    ForEach(0 ..< 3, id: \.self) { index in
                        HStack(spacing: Theme.Space.row) {
                            // The glyph tile's own shape, so the real rows land
                            // exactly where their placeholders were.
                            RoundedRectangle(cornerRadius: 34 * 0.24, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                                .frame(width: 34, height: 34)
                            bar(width: 120, height: 12)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.inset)
                        .padding(.vertical, 14)
                        if index < 2 { LearnRowDivider() }
                    }
                }
            }
        }
        .opacity(dim ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lernstand wird geladen")
    }

    /// A capsule rather than a fourth corner radius: a placeholder for a line of
    /// text is not a surface, and the area has exactly three radii.
    private func bar(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color(.tertiarySystemFill))
            .frame(width: width, height: height)
    }
}
