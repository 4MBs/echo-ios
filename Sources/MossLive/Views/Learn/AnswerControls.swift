import SwiftUI

// The two controls a written card needs: somewhere to write, and the judgement
// afterwards. Separate from the question so the question screen is about the
// question.

/// Where a written answer goes — or, for an oral card, the instruction that
/// replaces it.
struct WrittenAnswerField: View {
    let isOral: Bool
    let isLocked: Bool
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        if isOral {
            Text("Laut antworten, dann vergleichen.")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Deine Antwort", text: $text, axis: .vertical)
                .font(.body)
                .lineLimit(2 ... 6)
                .textFieldStyle(.roundedBorder)
                .focused(focus)
                .disabled(isLocked)
                .submitLabel(.done)
                .onSubmit(onSubmit)
        }
    }
}

/// How it went, in two buttons.
///
/// Four equal buttons is the decision paralysis the spaced-repetition community
/// has been complaining about for years, and pass/fail is what it recommends
/// instead. The two finer grades stay reachable for the people who want them —
/// one level down, where they cost nothing to ignore.
///
/// Ratings are the scale `POST /learn/review` already takes: 0 missed, 1 hard,
/// 2 known, 3 easy.
struct RatingControls: View {
    /// Side by side normally; stacked when the window is a Slide Over slice or
    /// the type is large, so a label is never shortened to fit.
    let stacked: Bool
    let onRate: (Int) -> Void

    var body: some View {
        let controls = Group {
            Button("Wusste ich nicht") { onRate(0) }
                .buttonStyle(.bordered)
                .keyboardShortcut("1", modifiers: [])
                .frame(maxWidth: .infinity)
            Button("Wusste ich") { onRate(2) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("2", modifiers: [])
                .frame(maxWidth: .infinity)
            Menu {
                Button("War schwer") { onRate(1) }
                Button("War leicht") { onRate(3) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Genauer bewerten")
        }
        return Group {
            if stacked {
                VStack(spacing: 10) { controls }
            } else {
                HStack(spacing: 10) { controls }
            }
        }
        .controlSize(.large)
    }
}
