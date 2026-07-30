import SwiftUI

struct TranscriptEditorView: View {
    let api: BackendAPI
    let lesson: BackendAPI.LessonDetail
    let onApply: (BackendAPI.LessonDetail) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [EditableTranscriptRow]
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var showingHistory = false

    init(
        api: BackendAPI,
        lesson: BackendAPI.LessonDetail,
        onApply: @escaping (BackendAPI.LessonDetail) -> Void
    ) {
        self.api = api
        self.lesson = lesson
        self.onApply = onApply
        _rows = State(initialValue: lesson.segments.map(EditableTranscriptRow.init))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($rows) { $row in
                        transcriptRow($row)
                    }
                } footer: {
                    Text(
                        "Zeitstempel bleiben beim Bearbeiten erhalten. "
                            + "Zeilenumbrüche in einem Feld werden beim Speichern zu getrennten Absätzen."
                    )
                }
            }
            .navigationTitle("Transkript bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingHistory = true
                    } label: {
                        Label("Versionen", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        Task { await save() }
                    }
                    .disabled(saving || rows.isEmpty)
                }
            }
            .overlay {
                if saving {
                    ProgressView("Transkript wird gespeichert…")
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .alert("Transkript konnte nicht gespeichert werden", isPresented: errorIsVisible) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showingHistory) {
                TranscriptHistoryView(api: api, lesson: lesson) { restored in
                    onApply(restored)
                    dismiss()
                }
            }
        }
    }

    private func transcriptRow(_ row: Binding<EditableTranscriptRow>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(timestamp(row.wrappedValue.t0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Mit vorherigem verbinden", systemImage: "arrow.up.to.line.compact") {
                        mergeWithPrevious(row.wrappedValue.id)
                    }
                    .disabled(rows.first?.id == row.wrappedValue.id)
                    Button("Absatz entfernen", systemImage: "trash", role: .destructive) {
                        rows.removeAll { $0.id == row.wrappedValue.id }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            TextEditor(text: row.text)
                .frame(minHeight: 74)
                .scrollContentBackground(.hidden)
        }
        .padding(.vertical, 4)
    }

    private func mergeWithPrevious(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let previous = rows[index - 1]
        let current = rows[index]
        rows[index - 1] = EditableTranscriptRow(
            t0: previous.t0,
            t1: current.t1,
            speaker: previous.speaker,
            text: [previous.text, current.text].filter { !$0.isEmpty }.joined(separator: " ")
        )
        rows.remove(at: index)
    }

    private func save() async {
        saving = true
        errorMessage = nil
        do {
            let updated = try await api.saveTranscript(
                id: lesson.id,
                segments: expandedSegments,
                expectedRevision: lesson.transcriptRevision
            )
            onApply(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }

    private var expandedSegments: [TranscriptSegment] {
        rows.flatMap { row in
            let paragraphs = row.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard paragraphs.count > 1 else {
                return [
                    TranscriptSegment(
                        t0: row.t0,
                        t1: row.t1,
                        speaker: row.speaker,
                        text: paragraphs.first ?? row.text
                    ),
                ]
            }
            let span = max(0.001, row.t1 - row.t0)
            return paragraphs.enumerated().map { index, text in
                let start = row.t0 + span * Double(index) / Double(paragraphs.count)
                let end = row.t0 + span * Double(index + 1) / Double(paragraphs.count)
                return TranscriptSegment(t0: start, t1: end, speaker: row.speaker, text: text)
            }
        }
    }

    private var errorIsVisible: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct EditableTranscriptRow: Identifiable {
    let id: UUID
    var t0: Double
    var t1: Double
    var speaker: String
    var text: String

    init(_ segment: TranscriptSegment) {
        self.init(t0: segment.t0, t1: segment.t1, speaker: segment.speaker, text: segment.text)
    }

    init(t0: Double, t1: Double, speaker: String, text: String) {
        id = UUID()
        self.t0 = t0
        self.t1 = t1
        self.speaker = speaker
        self.text = text
    }
}

private struct TranscriptHistoryView: View {
    let api: BackendAPI
    let lesson: BackendAPI.LessonDetail
    let onRestore: (BackendAPI.LessonDetail) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var history: BackendAPI.TranscriptHistory?
    @State private var loading = true
    @State private var restoring = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(
                        "Aktuelle Version",
                        value: "\(history?.currentRevision ?? lesson.transcriptRevision)"
                    )
                    LabeledContent(
                        "Manuelle Korrekturen",
                        value: (history?.hasManualEdits ?? lesson.hasManualEdits) ? "Vorhanden" : "Keine"
                    )
                }
                Section("Gespeicherte Versionen") {
                    if loading {
                        ProgressView()
                    } else if let revisions = history?.revisions, !revisions.isEmpty {
                        ForEach(revisions) { revision in
                            Button {
                                Task { await restore(revision.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(versionTitle(revision))
                                    Text(revision.createdAt.replacingOccurrences(of: "T", with: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(restoring)
                        }
                    } else {
                        Text("Noch keine frühere Version.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Ursprüngliches Live-Transkript wiederherstellen", role: .destructive) {
                        Task { await restoreOriginal() }
                    }
                    .disabled(restoring || history?.revisions.isEmpty != false)
                } footer: {
                    Text("Die aktuelle Fassung wird zuvor ebenfalls als Version gesichert.")
                }
            }
            .navigationTitle("Versionsverlauf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task { await load() }
            .alert("Version konnte nicht geladen werden", isPresented: errorIsVisible) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func load() async {
        do {
            history = try await api.transcriptHistory(id: lesson.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func restore(_ revisionId: Int) async {
        restoring = true
        do {
            let restored = try await api.restoreTranscript(
                id: lesson.id,
                revisionId: revisionId
            )
            onRestore(restored)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        restoring = false
    }

    private func restoreOriginal() async {
        restoring = true
        do {
            let restored = try await api.restoreOriginalTranscript(id: lesson.id)
            onRestore(restored)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        restoring = false
    }

    private func versionTitle(_ revision: BackendAPI.TranscriptRevisionInfo) -> String {
        switch revision.reason {
        case "retranscription_candidate":
            "Neue 48-kHz-Fassung (nicht angewendet)"
        case let reason where reason.hasPrefix("before_manual_edit"):
            "Vor manueller Bearbeitung"
        case let reason where reason.hasPrefix("before_manual_retranscription"):
            "Vor 48-kHz-Neutranskription"
        case let reason where reason.hasPrefix("before_restore"):
            "Vor Wiederherstellung"
        default:
            "Version \(revision.revision)"
        }
    }

    private var errorIsVisible: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
