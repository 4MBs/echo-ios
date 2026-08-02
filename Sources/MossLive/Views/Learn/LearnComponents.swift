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

/// The subject's colour as identity, at the size the system uses for a list
/// marker. Never the only thing carrying a meaning — the subject's name is
/// always written next to it.
struct SubjectDot: View {
    let subject: String?
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(subjectStyle(for: subject).tint.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
/// Full width up to a limit, because a 1300pt-wide button is not a button any
/// more; large control size, because it is the thing the screen exists for.
/// Words, no glyph: the button is already the largest control on the screen and
/// an icon on it would be decoration.
struct LearnPrimaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: Theme.Width.action)
    }
}

/// Three grey lines while the very first load runs and there is nothing stored
/// to show instead. Not a spinner in the middle of an empty screen: the shape of
/// the answer is already known, only its content is not.
struct LearnSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            bar(width: 180, height: 26)
            bar(width: 260, height: 16)
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(height: 50)
                .frame(maxWidth: Theme.Width.action)
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
