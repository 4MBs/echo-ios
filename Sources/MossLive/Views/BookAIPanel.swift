import AVFoundation
import SwiftUI
import UIKit

/// The book reader's contextual assistant. It is deliberately an action on
/// the page, not a second general-purpose Chat tab: the active page or marked
/// rectangle is always visible beside the composer, and every context keeps a
/// separate short-lived thread.
struct BookAIPanel: View {
    @Environment(AppModel.self) private var model

    let bookID: String
    let bookTitle: String
    let numbering: BookPageNumbering
    let visiblePages: [Int]
    let region: BackendAPI.BookPageRegion?
    let store: BookAIStore
    @Binding var detent: PresentationDetent
    let goToPage: (Int) -> Void
    let requestRegion: () -> Void
    let clearRegion: () -> Void
    let close: () -> Void

    @FocusState private var inputFocused: Bool
    @FocusState private var exerciseFocused: Bool
    @State private var exerciseNumber = ""
    @State private var enteringExercise = false
    @State private var expandedCitations: Set<UUID> = []
    @State private var showingInfo = false
    @State private var speaker = BookAnswerSpeaker()
    @State private var scopedContext: BookAIStore.Context?
    @State private var citationDestination: Int?

    private static let bottomID = "page-question-bottom"

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    private var incomingContext: BookAIStore.Context {
        BookAIStore.Context(
            pages: region.map { [$0.pdfPage] } ?? visiblePages,
            region: region
        )
    }

    /// A citation temporarily turns the book without changing what the open
    /// answer and its follow-ups are about. The next page turn made by the
    /// student adopts the new page normally.
    private var context: BookAIStore.Context {
        scopedContext ?? incomingContext
    }

    private var activeRegion: BackendAPI.BookPageRegion? { context.region }

    private var pageLabel: String {
        numbering.printedLabel(forVisible: context.pages)
    }

    private var contextLabel: String {
        activeRegion == nil ? "Seite \(pageLabel)" : "Markierter Bereich · Seite \(pageLabel)"
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color(.systemBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .navigationTitle("Seite \(pageLabel)")
                .navigationSubtitle(bookTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .onAppear {
            scopedContext = incomingContext
            store.activate(incomingContext)
        }
        .onChange(of: incomingContext) { _, newContext in
            guard citationDestination == nil else { return }
            scopedContext = newContext
            store.activate(newContext)
        }
        .onChange(of: visiblePages) { _, pages in
            guard let destination = citationDestination, pages.contains(destination) else { return }
            citationDestination = nil
        }
        .onChange(of: store.turns.count) { _, _ in detent = .large }
        .alert("So arbeitet „Seite fragen“", isPresented: $showingInfo) {
            Button("OK") {}
        } message: {
            Text(
                "Deine Frage wird an deinen eigenen Server gesendet. Das Buch liegt dort bereits; "
                    + "die Buchseite wird nicht hochgeladen. KI-Antworten können Fehler enthalten — "
                    + "prüfe deshalb die angegebenen Seiten."
            )
        }
    }

    // MARK: - Navigation

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Schließen")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Hinweise & Datenschutz", systemImage: "info.circle") {
                    showingInfo = true
                }
                Divider()
                Button("Verlauf dieser Seite leeren", systemImage: "eraser") {
                    store.clear()
                }
                .disabled(!store.hasContent)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Mehr")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.turns.isEmpty, store.pending == nil, store.errorMessage == nil {
            startView
        } else {
            thread
        }
    }

    private var startView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Wobei soll ich helfen?")
                        .font(.title3.weight(.semibold))
                    Text(activeRegion == nil
                        ? "Wähle eine Aktion oder stelle unten eine eigene Frage."
                        : "Die nächste Frage bezieht sich nur auf den markierten Bereich.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if enteringExercise {
                    exerciseEntry
                }

                VStack(spacing: 1) {
                    startAction(
                        title: "Aufgabe lösen",
                        subtitle: "Eine bestimmte Aufgabennummer eingeben",
                        symbol: "function"
                    ) {
                        enteringExercise = true
                        Task {
                            try? await Task.sleep(for: .milliseconds(80))
                            exerciseFocused = true
                        }
                    }
                    startAction(
                        title: "Seite erklären",
                        subtitle: "Die Zusammenhänge verständlich erklären",
                        symbol: "text.book.closed"
                    ) { send("Erkläre diese Seite verständlich.") }
                    startAction(
                        title: "Kurz zusammenfassen",
                        subtitle: "Die wichtigsten Punkte in wenigen Sätzen",
                        symbol: "text.alignleft"
                    ) { send("Fasse diese Seite in wenigen Sätzen zusammen.") }
                    startAction(
                        title: "Abbildung erklären",
                        subtitle: "Karte, Diagramm oder Bild untersuchen",
                        symbol: "photo"
                    ) { send("Erkläre die Abbildung auf dieser Seite.") }
                    startAction(
                        title: activeRegion == nil ? "Bereich markieren" : "Anderen Bereich markieren",
                        subtitle: "Mit Finger oder Apple Pencil genau auswählen",
                        symbol: "rectangle.dashed"
                    ) { requestRegion() }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous)
                        .stroke(.primary.opacity(0.07), lineWidth: 0.5)
                }
            }
            .padding(Theme.Space.inset)
        }
    }

    private func startAction(
        title: String,
        subtitle: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canAsk)
    }

    private var exerciseEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welche Aufgabe?")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Text("Aufgabe")
                    .foregroundStyle(.secondary)
                TextField("z. B. 4b", text: $exerciseNumber)
                    .textFieldStyle(.roundedBorder)
                    .focused($exerciseFocused)
                    .submitLabel(.send)
                    .onSubmit(sendExercise)
                Button("Lösen", action: sendExercise)
                    .buttonStyle(.borderedProminent)
                    .disabled(exerciseNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Space.inset)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(store.turns) { turn in
                        exchange(turn)
                            .id(turn.id)
                    }
                    if let pending = store.pending {
                        working(pending.question)
                    }
                    if let error = store.errorMessage {
                        failure(error)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.inset)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.turns.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store.sending) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func exchange(_ turn: BookAIStore.Turn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.question)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Echo · KI-Antwort")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(renderedMarkdown(turn.text))
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !sources(for: turn).isEmpty {
                citationDisclosure(turn)
            }

            responseActions(turn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func citationDisclosure(_ turn: BookAIStore.Turn) -> some View {
        let citations = sources(for: turn)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    if expandedCitations.contains(turn.id) {
                        expandedCitations.remove(turn.id)
                    } else {
                        expandedCitations.insert(turn.id)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "text.book.closed")
                    Text(citationSummary(citations))
                    Spacer(minLength: 4)
                    Image(systemName: expandedCitations.contains(turn.id) ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
            .buttonStyle(.plain)

            if expandedCitations.contains(turn.id) {
                ForEach(citations) { citation in
                    Button {
                        citationDestination = visiblePages.contains(citation.pdfPage) ? nil : citation.pdfPage
                        detent = .medium
                        goToPage(citation.pdfPage)
                    } label: {
                        HStack(spacing: 10) {
                            Text(numbering.citationLabel(pdfPage: citation.pdfPage))
                                .font(.subheadline.weight(.medium))
                            if !citation.note.isEmpty {
                                Text(citation.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!numbering.contains(pdfPage: citation.pdfPage))
                    .accessibilityHint("Zeigt diese Seite im Buch")
                }
            }
        }
    }

    private func citationSummary(_ citations: [BackendAPI.BookCitation]) -> String {
        let pages = citations.map { numbering.citationLabel(pdfPage: $0.pdfPage) }
        return "\(citations.count) \(citations.count == 1 ? "Quelle" : "Quellen"): \(pages.joined(separator: ", "))"
    }

    /// Older servers sometimes return only `pages_read`; keep those useful and
    /// tappable, while preferring the richer citation note when both describe
    /// the same page.
    private func sources(for turn: BookAIStore.Turn) -> [BackendAPI.BookCitation] {
        var result = turn.citations
        let cited = Set(result.map(\.pdfPage))
        result.append(contentsOf: turn.pagesRead.filter { !cited.contains($0) }.map {
            BackendAPI.BookCitation(pdfPage: $0, note: "Von der KI geprüft")
        })
        return result.sorted { $0.pdfPage < $1.pdfPage }
    }

    private func responseActions(_ turn: BookAIStore.Turn) -> some View {
        HStack(spacing: 2) {
            Button {
                UIPasteboard.general.string = turn.text
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Antwort kopieren")

            Button {
                speaker.speak(turn.text)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Antwort vorlesen")

            ShareLink(item: shareText(turn)) {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Antwort teilen")

            Menu {
                Button("Kürzer erklären", systemImage: "text.badge.minus") {
                    store.ask(
                        "Erkläre diese Antwort kürzer und einfacher.",
                        bookID: bookID,
                        api: api,
                        after: turn
                    )
                }
                Button("Erneut versuchen", systemImage: "arrow.clockwise") {
                    store.retry(turn, bookID: bookID, api: api)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Weitere Antwortaktionen")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func shareText(_ turn: BookAIStore.Turn) -> String {
        let sources = sources(for: turn).map {
            numbering.citationLabel(pdfPage: $0.pdfPage)
        }.joined(separator: ", ")
        return sources.isEmpty
            ? "\(turn.text)\n\nMit Echo aus \(bookTitle)"
            : "\(turn.text)\n\nQuellen: \(sources)\nMit Echo aus \(bookTitle)"
    }

    private func working(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 48)
                Text(question)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(activeRegion == nil
                    ? "Analysiert Text und Abbildungen auf Seite \(pageLabel)…"
                    : "Analysiert den markierten Bereich…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Stoppen") { store.cancel() }
                    .font(.caption)
                    .frame(minHeight: 44)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            if let failed = store.lastFailed, model.connectivity.isOnline {
                Button("Erneut versuchen") {
                    store.ask(failed.question, bookID: bookID, api: api)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Theme.Space.inset)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !model.connectivity.isOnline {
                Label("Ohne Serververbindung — Lesen geht weiter, Fragen nicht.", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu {
                Button("Aktuelle Seite", systemImage: "doc") {
                    citationDestination = nil
                    let pageContext = BookAIStore.Context(pages: visiblePages)
                    scopedContext = pageContext
                    store.activate(pageContext)
                    clearRegion()
                }
                .disabled(activeRegion == nil && context.pages == visiblePages)
                Button("Bereich markieren", systemImage: "rectangle.dashed") { requestRegion() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: activeRegion == nil ? "doc" : "rectangle.dashed")
                    Text(contextLabel)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.tint)
                .frame(minHeight: 44)
            }

            if !store.sending, !store.turns.isEmpty {
                followUps
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(fieldPrompt, text: draftBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: Capsule())

                Button {
                    if store.sending { store.cancel() } else { sendDraft() }
                } label: {
                    Image(systemName: store.sending ? "stop.fill" : "arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!store.sending && !canSend)
                .accessibilityLabel(store.sending ? "Antwort stoppen" : "Frage senden")
            }
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private var followUps: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                followUp("Einfacher", "Erkläre die vorige Antwort noch einmal einfacher.")
                followUp("Beispiel", "Gib mir ein konkretes Beispiel dazu.")
                followUp("Schritt für Schritt", "Zeig mir das Schritt für Schritt.")
                followUp("Warum?", "Warum ist das so?")
            }
        }
        .scrollIndicators(.hidden)
    }

    private func followUp(_ label: String, _ question: String) -> some View {
        Button(label) { send(question) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .frame(minHeight: 44)
            .disabled(!canAsk)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { store.draft }, set: { store.draft = $0 })
    }

    private var fieldPrompt: String {
        store.turns.isEmpty ? "Frage zu \(contextLabel.lowercased())…" : "Nachfragen…"
    }

    private var canAsk: Bool {
        !store.sending && model.connectivity.isOnline && !context.pages.isEmpty
    }

    private var canSend: Bool {
        store.canSend && canAsk
    }

    private func send(_ question: String) {
        guard canAsk else { return }
        inputFocused = false
        store.ask(question, bookID: bookID, api: api)
    }

    private func sendDraft() {
        guard canSend else { return }
        send(store.draft)
    }

    private func sendExercise() {
        let number = exerciseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return }
        enteringExercise = false
        exerciseFocused = false
        exerciseNumber = ""
        send("Löse Aufgabe \(number) Schritt für Schritt.")
    }
}

/// Kept alive by the panel while it is presented; creating a synthesizer for
/// every tap can make the first words disappear when SwiftUI redraws.
private final class BookAnswerSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "de-DE")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}
