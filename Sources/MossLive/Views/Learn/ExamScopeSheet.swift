import SwiftUI

/// Which lessons an exam covers.
///
/// One list, used twice: pushed inside the create form, and presented as a sheet
/// from "Stoff bearbeiten". Choosing eighteen lessons is something a student
/// does once and then almost never, so it is never in the way of the four fields
/// that matter.
struct ExamScopeList: View {
    let subject: String
    let lessons: [BackendAPI.LessonInfo]
    @Binding var selected: Set<String>

    var body: some View {
        List {
            Section {
                if lessons.isEmpty {
                    Text("In diesem Zeitraum wurde in \(subject) nichts aufgenommen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(lessons) { lesson in
                        Button { toggle(lesson.id) } label: {
                            LessonPickRow(lesson: lesson, subject: subject, isOn: selected.contains(lesson.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("Echo lernt nur aus den ausgewählten Stunden.")
            }
        }
        .navigationTitle("Stunden")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}

/// The same list as a sheet, for changing the material of an exam that already
/// exists.
struct ExamScopeSheet: View {
    let subject: String
    let lessons: [BackendAPI.LessonInfo]
    let onSave: @MainActor (Set<String>) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var saving = false

    init(
        subject: String,
        lessons: [BackendAPI.LessonInfo],
        selected: Set<String>,
        onSave: @escaping @MainActor (Set<String>) async -> Void
    ) {
        self.subject = subject
        self.lessons = lessons.sortedNewestFirst
        self.onSave = onSave
        _selected = State(initialValue: selected)
    }

    var body: some View {
        NavigationStack {
            ExamScopeList(subject: subject, lessons: lessons, selected: $selected)
                .navigationTitle("Stoff")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Sichert …" : "Sichern") {
                            saving = true
                            Task {
                                await onSave(selected)
                                saving = false
                                dismiss()
                            }
                        }
                        .disabled(saving || selected.isEmpty)
                    }
                }
        }
    }
}

/// One lesson, on or off.
struct LessonPickRow: View {
    let lesson: BackendAPI.LessonInfo
    let subject: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lesson.topic ?? lesson.summaryExcerpt ?? subject)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(LearnDay.short(lesson.startedAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? Theme.accent : Color.secondary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
