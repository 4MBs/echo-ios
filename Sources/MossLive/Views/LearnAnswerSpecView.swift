import SwiftUI

struct LearnAnswerSpecView: View {
    let spec: BackendAPI.LearnAnswerSpec?
    @Binding var answer: String

    var body: some View {
        switch spec?.type {
        case "choice":
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array((spec?.options ?? []).enumerated()), id: \.offset) { index, option in
                    Button {
                        answer = String(index)
                    } label: {
                        HStack {
                            Image(systemName: answer == String(index) ? "largecircle.fill.circle" : "circle")
                            Text(option).multilineTextAlignment(.leading)
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(answer == String(index) ? Theme.accent : .secondary)
                }
            }
        case "number":
            HStack {
                TextField("Ergebnis", text: $answer)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                if let unit = spec?.unit, !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        case "cloze":
            StructuredFields(fields: spec?.blanks ?? [], answer: $answer, fallback: "Lücke")
        case "orderedSteps":
            StructuredFields(
                fields: (spec?.steps ?? []).indices.map {
                    BackendAPI.LearnAnswerSpec.Field(id: "\($0)", label: "Schritt \($0 + 1)", expected: nil)
                },
                answer: $answer,
                fallback: "Schritt"
            )
        default:
            TextEditor(text: $answer)
                .frame(minHeight: 150)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("Deine Antwort")
                .accessibilityIdentifier("learn.answer")
        }
    }
}

private struct StructuredFields: View {
    let fields: [BackendAPI.LearnAnswerSpec.Field]
    @Binding var answer: String
    let fallback: String

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                TextField(field.label ?? "\(fallback) \(index + 1)", text: binding(index))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding {
            let values = answer.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return values.indices.contains(index) ? values[index] : ""
        } set: { value in
            var values = answer.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            while values.count <= index {
                values.append("")
            }
            values[index] = value
            answer = values.joined(separator: "|")
        }
    }
}
