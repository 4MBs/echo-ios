import SwiftUI

/// One answer option: a full-width row, tall enough for a thumb, that says what
/// happened with a symbol and a colour rather than with a colour alone.
struct OptionRow: View {
    /// Named `Status` rather than `State`: a type called `State` inside a `View`
    /// shadows the property wrapper for everything below it.
    enum Status {
        case idle
        case correct
        case wrong
        case dimmed
    }

    let letter: String
    let text: String
    let state: Status

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.row) {
            marker
            Text(text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 14)
        .frame(minHeight: 60)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .opacity(state == .dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        // Pointer feedback: on an iPad with a keyboard case the answer is often
        // chosen with a trackpad rather than a finger. Once answered the button
        // is disabled, so this stops applying by itself.
        .hoverEffect(.highlight)
    }

    @ViewBuilder
    private var marker: some View {
        switch state {
        case .correct:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .font(.title3)
        case .wrong:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)
                .font(.title3)
        case .idle, .dimmed:
            Text(letter)
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
    }

    private var background: Color {
        switch state {
        case .correct: Color.green.opacity(0.12)
        case .wrong: Color.red.opacity(0.12)
        case .idle, .dimmed: Color(.secondarySystemBackground)
        }
    }

    private var border: Color {
        switch state {
        case .correct: Color.green.opacity(0.5)
        case .wrong: Color.red.opacity(0.5)
        case .idle, .dimmed: Color(.separator)
        }
    }
}
