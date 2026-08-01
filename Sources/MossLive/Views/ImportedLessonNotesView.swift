import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

/// External notes attached to one recorded lesson. Echo deliberately does not
/// offer a canvas or text editor here: Goodnotes, Notability and any PDF/image
/// app remain the place where the notes are authored.
struct ImportedLessonNotesView: View {
    let api: BackendAPI
    let lesson: BackendAPI.LessonInfo
    let player: LessonAudioPlayer

    @Environment(\.dismiss) private var dismiss

    @State private var notes: [BackendAPI.LessonNote] = []
    @State private var warnings: [String] = []
    @State private var loading = true
    @State private var importing = false
    @State private var showingImporter = false
    @State private var errorMessage: String?
    @State private var sharedDocument: SharedNoteDocument?

    var body: some View {
        NavigationStack {
            List {
                explanation
                if !warnings.isEmpty {
                    warningSection
                }
                if loading {
                    Section { ProgressView("Importe werden geladen…") }
                } else if notes.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Noch keine Notizen importiert",
                            systemImage: "doc.badge.arrow.up",
                            description: Text(
                                "Importiere eine Goodnotes- oder Notability-Datei, ein PDF oder ein Bild."
                            )
                        )
                    }
                } else {
                    Section("Importierte Seiten") {
                        ForEach(notes) { note in
                            HStack(spacing: 10) {
                                NavigationLink {
                                    ImportedNotePageView(note: note)
                                } label: {
                                    ImportedNoteRow(note: note)
                                }
                                if note.timingSource == "page_modified", lesson.hasAudio {
                                    Button {
                                        play(note)
                                    } label: {
                                        Label(
                                            Self.clock(note.offsetSeconds),
                                            systemImage: "play.circle.fill"
                                        )
                                        .font(.caption.monospacedDigit())
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(
                                        "Audio ab \(Self.clock(note.offsetSeconds)) abspielen"
                                    )
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Löschen", role: .destructive) {
                                    Task { await delete(note) }
                                }
                            }
                            .contextMenu {
                                if note.timingSource == "page_modified", lesson.hasAudio {
                                    Button {
                                        play(note)
                                    } label: {
                                        Label("Audio ab diesem Zeitpunkt", systemImage: "play.fill")
                                    }
                                }
                                if note.hasAttachment {
                                    Button {
                                        Task { await openOriginal(note) }
                                    } label: {
                                        Label("Original öffnen oder teilen", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Unterrichtsnotizen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if importing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Dokument importieren", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importing)
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: Self.importTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImportSelection
        )
        .sheet(item: $sharedDocument) { document in
            NoteDocumentShareSheet(url: document.url)
        }
        .alert("Import nicht möglich", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unbekannter Fehler")
        }
        .task { await load() }
    }

    private var explanation: some View {
        Section {
            Label {
                Text(
                    "Echo liest vorhandene Notizen als Unterrichtskontext. "
                        + "Bei Goodnotes kann die letzte Seitenänderung mit der Aufnahme verbunden werden; "
                        + "sie ist kein exakter Zeitstempel jedes Pencil-Strichs."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var warningSection: some View {
        Section("Hinweise von Goodnotes") {
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in
                if !presented { errorMessage = nil }
            }
        )
    }

    private static var importTypes: [UTType] {
        var types: [UTType] = [.pdf, .jpeg, .png]
        if let goodnotes = UTType(filenameExtension: "goodnotes") { types.append(goodnotes) }
        if let notability = UTType(filenameExtension: "note") { types.append(notability) }
        return types
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importDocument(url) }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func load() async {
        do {
            notes = try await api.lessonNotes(id: lesson.id)
                .sorted(by: Self.noteOrder)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func importDocument(_ url: URL) async {
        importing = true
        defer { importing = false }
        do {
            let recognizedText = await Self.recognizedImageText(at: url)
            let result = try await api.importLessonNotes(
                sessionId: lesson.id,
                fileURL: url,
                recognizedText: recognizedText
            )
            warnings = result.warnings
            notes = try await api.lessonNotes(id: lesson.id)
                .sorted(by: Self.noteOrder)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ note: BackendAPI.LessonNote) async {
        do {
            try await api.deleteLessonNote(sessionId: lesson.id, noteId: note.id)
            notes.removeAll { $0.id == note.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(_ note: BackendAPI.LessonNote) {
        Task {
            if await player.ensureLoaded(api: api, lessonId: lesson.id) {
                player.playFrom(note.offsetSeconds)
                dismiss()
            }
        }
    }

    private func openOriginal(_ note: BackendAPI.LessonNote) async {
        do {
            let url = try await api.downloadLessonNoteAttachment(
                sessionId: lesson.id,
                noteId: note.id
            )
            sharedDocument = SharedNoteDocument(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func noteOrder(_ lhs: BackendAPI.LessonNote, _ rhs: BackendAPI.LessonNote) -> Bool {
        if lhs.offsetSeconds != rhs.offsetSeconds { return lhs.offsetSeconds < rhs.offsetSeconds }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    /// Images have no searchable text container, so Vision supplies the text
    /// that the backend will use as lesson context. PDF and native note formats
    /// are decoded on the server and intentionally skip this path.
    private static func recognizedImageText(at url: URL) async -> String {
        guard ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) else { return "" }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["de-DE", "en-US"]
            let handler = VNImageRequestHandler(url: url, options: [:])
            guard (try? handler.perform([request])) != nil else { return "" }
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

private struct ImportedNoteRow: View {
    let note: BackendAPI.LessonNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(note.title, systemImage: "doc.text")
                .font(.headline)
            if !note.textContent.isEmpty {
                Text(note.textContent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let filename = note.originalFilename {
                Label(filename, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if note.timingSource != "page_modified" {
                Text("ohne Zeitpunkt")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ImportedNotePageView: View {
    let note: BackendAPI.LessonNote

    var body: some View {
        ScrollView {
            Text(note.textContent.isEmpty ? "Kein durchsuchbarer Text gefunden." : note.textContent)
                .font(.body)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SharedNoteDocument: Identifiable {
    let id = UUID()
    let url: URL
}

private struct NoteDocumentShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
