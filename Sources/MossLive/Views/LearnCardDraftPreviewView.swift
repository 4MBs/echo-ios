import SwiftUI

struct LearnCardDraftPreviewView: View {
    let api: BackendAPI
    let sessionId: String
    let initialDrafts: [BackendAPI.LearnCardDraft]
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [BackendAPI.LearnCardDraft]
    @State private var selection: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmDiscard = false
    @State private var regenerating: String?

    init(
        api: BackendAPI,
        sessionId: String,
        drafts: [BackendAPI.LearnCardDraft],
        onSaved: @escaping () async -> Void
    ) {
        self.api = api
        self.sessionId = sessionId
        initialDrafts = drafts
        self.onSaved = onSaved
        _drafts = State(initialValue: drafts)
        _selection = State(initialValue: drafts.first?.id)
    }

    var body: some View {
        NavigationStack {
            List {
                if let index = selectedIndex {
                    Section("Karte bearbeiten") {
                        TextField("Konzept", text: $drafts[index].concept)
                        TextField("Frage", text: $drafts[index].question, axis: .vertical)
                            .lineLimit(2 ... 6)
                        TextField(
                            "Erwartete Antwort",
                            text: Binding(
                                get: { drafts[index].expectedAnswer ?? "" },
                                set: { drafts[index].expectedAnswer = $0 }
                            ),
                            axis: .vertical
                        )
                        .lineLimit(2 ... 8)
                        TextField("Erklärung", text: $drafts[index].explanation, axis: .vertical)
                            .lineLimit(2 ... 6)
                        Stepper(
                            "Schwierigkeit \(drafts[index].difficulty) von 5",
                            value: $drafts[index].difficulty,
                            in: 1 ... 5
                        )
                        Button("Diese Karte neu formulieren", systemImage: "arrow.clockwise") {
                            Task { await regenerate(index) }
                        }
                        .disabled(regenerating != nil)
                    }

                    Section("Entwürfe") {
                        ForEach(drafts) { draft in
                            Button {
                                selection = draft.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(draft.concept).font(.headline)
                                        Text(draft.question).font(.caption).lineLimit(2)
                                    }
                                    Spacer()
                                    if selection == draft.id {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                            .swipeActions {
                                Button("Verwerfen", role: .destructive) { remove(draft.id) }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Keine Karten ausgewählt", systemImage: "rectangle.stack.badge.minus")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Lernkarten prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { confirmDiscard = !drafts.isEmpty }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") { Task { await save() } }
                        .disabled(drafts.isEmpty || isSaving)
                }
            }
            .confirmationDialog("Ungespeicherte Karten verwerfen?", isPresented: $confirmDiscard) {
                Button("Verwerfen", role: .destructive) { dismiss() }
                Button("Weiter bearbeiten", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(!drafts.isEmpty)
    }

    private var selectedIndex: Int? {
        drafts.firstIndex { $0.id == selection }
    }

    private func remove(_ id: String) {
        drafts.removeAll { $0.id == id }
        if selection == id { selection = drafts.first?.id }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            _ = try await api.saveLearnDrafts(drafts, sessionId: sessionId)
            drafts = []
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func regenerate(_ index: Int) async {
        regenerating = drafts[index].id
        errorMessage = nil
        do {
            let replacement = try await api.regenerateLearnDraft(drafts[index])
            drafts[index] = replacement
            selection = replacement.id
        } catch { errorMessage = error.localizedDescription }
        regenerating = nil
    }
}
