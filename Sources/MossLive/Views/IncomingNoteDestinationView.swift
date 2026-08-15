import SwiftUI

struct IncomingNoteDestinationView: View {
    let item: PendingNoteImports.Item
    let api: BackendAPI
    let coordinator: IncomingNoteImportCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var loading = true
    @State private var loadError: Error?
    @State private var player = LessonAudioPlayer()

    var body: some View {
        Group {
            if let lesson = coordinator.completedLesson {
                ImportedLessonNotesView(api: api, lesson: lesson, player: player)
            } else {
                NavigationStack {
                    Group {
                        if loading {
                            ProgressView("Stunden werden geladen…")
                        } else if let loadError {
                            ErrorState(loadError) { await load() }
                        } else if lessons.isEmpty {
                            ContentUnavailableView(
                                "Noch keine Stunde vorhanden",
                                systemImage: "clock.badge.questionmark",
                                description: Text("Nimm zuerst eine Stunde auf, um \(item.filename) zuzuordnen.")
                            )
                        } else {
                            lessonList
                        }
                    }
                    .navigationTitle("Stunde auswählen")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Abbrechen") { dismiss() }
                        }
                    }
                }
                .task { await load() }
            }
        }
        .alert("Import nicht möglich", isPresented: failurePresented) {
            Button("OK", role: .cancel) { coordinator.dismissStatus() }
        } message: {
            Text(coordinator.status.message ?? "Unbekannter Fehler")
        }
    }

    private var lessonList: some View {
        List {
            Section {
                Label(item.filename, systemImage: "doc.badge.arrow.up")
                    .lineLimit(2)
            } header: {
                Text("Geteilte Datei")
            }

            Section("Zur Stunde hinzufügen") {
                ForEach(lessons) { lesson in
                    Button {
                        coordinator.importIntoSelectedLesson(lesson, item: item, api: api)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                if let subject = lesson.displaySubject {
                                    Text(subject)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                                Text(lesson.displayTitle)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                            Text(lesson.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                    .disabled(isImporting)
                }
            }
        }
        .overlay {
            if isImporting {
                ProgressView("Dokument wird importiert…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var isImporting: Bool {
        if case .importing = coordinator.status { return true }
        return false
    }

    private var failurePresented: Binding<Bool> {
        Binding(
            get: { coordinator.status.isFailure },
            set: { presented in
                if !presented { coordinator.dismissStatus() }
            }
        )
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            lessons = try await api.listLessons().sorted { $0.startedAt > $1.startedAt }
        } catch {
            loadError = error
        }
        loading = false
    }
}
