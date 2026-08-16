import SwiftUI

/// Which subject a recording belongs to, picked from a list you can search.
///
/// This was a `confirmationDialog`, and a confirmation dialog is for a handful
/// of choices — not for a school's entire subject catalogue. With a dozen
/// subjects in it, iPadOS drew a popover that neither scrolled nor fitted: the
/// subjects past the fourth were cut off at its bottom edge, and the popover
/// itself lay across the sidebar. There was no way to reach "Physik".
///
/// A list holds any number of subjects because it scrolls, says which subject
/// the lesson has now instead of making you remember it, and can be searched —
/// which is faster than reading fifteen rows even when they do all fit.
struct SubjectChangeSheet: View {
    let title: String
    /// What the choice will apply to, in words: one lesson, or several.
    let footnote: String
    let catalogue: [BackendAPI.SubjectInfo]
    /// The subject the lesson has now, marked in the list. Nil when several
    /// lessons with different subjects were picked.
    let current: String?
    let onChoose: (BackendAPI.SubjectInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 22

    private var matches: [BackendAPI.SubjectInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return catalogue }
        return catalogue.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.short.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matches) { subject in
                        Button {
                            onChoose(subject)
                            dismiss()
                        } label: {
                            row(subject)
                        }
                        .accessibilityAddTraits(subject.name == current ? [.isSelected] : [])
                    }
                } footer: {
                    Text(footnote)
                }
            }
            .overlay {
                if matches.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Fach suchen")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ subject: BackendAPI.SubjectInfo) -> some View {
        let style = subjectStyle(for: subject.name)
        return HStack(spacing: 14) {
            Image(style.icon)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(style.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(subject.name)
                    .foregroundStyle(.primary)
                if !subject.teachers.isEmpty {
                    Text(subject.teachers.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if subject.name == current {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}
