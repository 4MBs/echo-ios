import SwiftUI

struct SubjectVocabularyView: View {
    let api: BackendAPI
    let subject: String

    @State private var terms: [BackendAPI.VocabularyTerm] = []
    @State private var newTerms = ""
    @State private var loading = true
    @State private var refreshing = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Begriff oder mehrere mit Komma", text: $newTerms)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }
                    Button("Hinzufügen") {
                        Task { await add() }
                    }
                    .disabled(saving || parsedTerms.isEmpty)
                }
            } footer: {
                Text("Diese Begriffe werden bei der manuellen 48-kHz-Neutranskription bevorzugt.")
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    if refreshing {
                        HStack {
                            ProgressView()
                            Text("Quellen werden durchsucht…")
                        }
                    } else {
                        Label("Vorschläge aus Quellen sammeln", systemImage: "text.magnifyingglass")
                    }
                }
                .disabled(refreshing)
            } footer: {
                Text(
                    "Durchsucht auf ausdrücklichen Wunsch frühere Stunden dieses Fachs, "
                        + "Lehrer und Räume sowie passende Schulbücher."
                )
            }

            Section("Begriffe") {
                if loading {
                    ProgressView()
                } else if terms.isEmpty {
                    Text("Noch keine Fachbegriffe.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(terms) { item in
                        HStack {
                            Text(item.term)
                            Spacer()
                            Text(sourceName(item.source))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        Task { await delete(offsets) }
                    }
                }
            }
        }
        .navigationTitle(subject)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Wörterbuch konnte nicht geändert werden", isPresented: errorIsVisible) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var parsedTerms: [String] {
        newTerms
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func load() async {
        do {
            terms = try await api.vocabulary(subject: subject)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func add() async {
        let additions = parsedTerms
        guard !additions.isEmpty else { return }
        saving = true
        do {
            terms = try await api.addVocabulary(subject: subject, terms: additions)
            newTerms = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }

    private func refresh() async {
        refreshing = true
        do {
            terms = try await api.refreshVocabulary(subject: subject)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshing = false
    }

    private func delete(_ offsets: IndexSet) async {
        let selected = offsets.compactMap { terms.indices.contains($0) ? terms[$0] : nil }
        do {
            for item in selected {
                try await api.deleteVocabulary(subject: subject, term: item.term)
            }
            terms.remove(atOffsets: offsets)
        } catch {
            errorMessage = error.localizedDescription
            await load()
        }
    }

    private func sourceName(_ source: String) -> String {
        switch source {
        case "manual": "Manuell"
        case "correction": "Korrektur"
        case "timetable": "Stundenplan"
        case "transcript": "Frühere Stunden"
        case "schoolbook": "Schulbuch"
        default: source
        }
    }

    private var errorIsVisible: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
