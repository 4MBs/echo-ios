import SwiftUI

/// "Notizen": a pinboard of handwritten sticky notes. Notes are written here
/// or as Schnellnotiz on the Aufnahme screen (then tagged with the lesson).
struct NotesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: NotesStore.Note?
    @State private var creating = false

    private var notes: NotesStore { model.notes }

    var body: some View {
        NavigationStack {
            content
                .paperScreen()
                .navigationTitle("Notizen")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            creating = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.accent)
                        }
                        .accessibilityLabel("Neue Notiz")
                    }
                }
                .sheet(isPresented: $creating) {
                    NoteEditorSheet(title: "Neue Notiz", initialText: "") { text in
                        notes.add(text: text)
                    }
                }
                .sheet(item: $editing) { note in
                    NoteEditorSheet(title: "Notiz bearbeiten", initialText: note.text) { text in
                        notes.update(note.id, text: text)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if notes.notes.isEmpty {
            VStack(spacing: 18) {
                Text("Noch keine Notizen.\nTippe auf +, um eine zu schreiben!")
                    .multilineTextAlignment(.center)
                    .stickyNote(rotation: -1.5)
                Text("Während einer Aufnahme kannst du oben rechts\neine Schnellnotiz zur laufenden Stunde machen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 22)], spacing: 26) {
                    ForEach(notes.notes) { note in
                        NoteCard(note: note)
                            .onTapGesture { editing = note }
                            .contextMenu {
                                Button(role: .destructive) {
                                    notes.delete(note.id)
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(22)
            }
        }
    }
}

/// One sticky note on the board.
private struct NoteCard: View {
    let note: NotesStore.Note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.text)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .stickyNote(rotation: note.rotationSeed)
    }

    private var footer: String {
        var parts = [note.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let lesson = note.lessonTitle, !lesson.isEmpty { parts.append(lesson) }
        return parts.joined(separator: " · ")
    }
}

/// Shared editor sheet for new notes, edits, and the Schnellnotiz.
struct NoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialText: String
    let onSave: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(Theme.handwriting(19))
                .scrollContentBackground(.hidden)
                .padding(14)
                .background(Theme.note)
                .focused($focused)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Speichern") {
                            onSave(text)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium])
        .onAppear {
            text = initialText
            focused = true
        }
    }
}
