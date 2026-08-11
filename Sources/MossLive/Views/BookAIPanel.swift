import AVFoundation
import SwiftUI
import UIKit

/// A page-scoped assistant presented by the book reader's adaptive inspector.
/// Navigation, bars, menus and controls are intentionally system components so
/// iOS can provide the appropriate Liquid Glass appearance and transitions.
struct BookAIPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var showingExercise = false
    @State private var exerciseNumber = ""
    @State private var expandedCitations: Set<UUID> = []
    @State private var copiedTurn: UUID?
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

    /// A citation can turn the book without silently moving the open answer to
    /// another context. The student's next page turn adopts that page normally.
    private var context: BookAIStore.Context { scopedContext ?? incomingContext }
    private var activeRegion: BackendAPI.BookPageRegion? { context.region }
    private var pageLabel: String { numbering.printedLabel(forVisible: context.pages) }
    private var contextLabel: String {
        activeRegion == nil ? "Seite \(pageLabel)" : "Markierter Bereich · Seite \(pageLabel)"
    }

    var body: some View {
        NavigationStack {
            rootContent
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .navigationTitle(contextLabel)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .background(Color(.systemBackground))
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
    }

    // MARK: - Navigation

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: close) {
                Label("Seite fragen", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("Seite fragen schließen")
        }
        if store.hasContent {
            ToolbarItem(placement: .topBarTrailing) {
                newQuestionMenu
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Verlauf dieser Seite leeren", systemImage: "eraser") {
                    store.clear()
                }
                .disabled(!store.hasContent)
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Mehr")
        }
    }

    private var newQuestionMenu: some View {
        Menu {
            Button("Aufgabe lösen", systemImage: "function", action: presentExercise)
                .disabled(!canAsk)
            Button("Seite erklären", systemImage: "text.book.closed") {
                send("Seite erklären", request: BookAIPrompts.explainPage)
            }
            .disabled(!canAsk)
            Button("Kurz zusammenfassen", systemImage: "text.alignleft") {
                send("Kurz zusammenfassen", request: BookAIPrompts.summarizePage)
            }
            .disabled(!canAsk)
            Button("Abbildung erklären", systemImage: "photo") {
                send("Abbildung erklären", request: BookAIPrompts.explainFigure)
            }
            .disabled(!canAsk)
            Divider()
            Button(
                activeRegion == nil ? "Bereich markieren" : "Anderen Bereich markieren",
                systemImage: "rectangle.dashed",
                action: requestRegion
            )
        } label: {
            Label("Neue Frage", systemImage: "square.and.pencil")
        }
        .accessibilityLabel("Neue Frage oder Aktion")
    }

    // MARK: - Start and actions

    @ViewBuilder
    private var rootContent: some View {
        if store.turns.isEmpty, store.pending == nil, store.errorMessage == nil {
            actionList
        } else {
            thread
        }
    }

    private var actionList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Wobei soll ich helfen?")
                        .font(.title3.weight(.semibold))
                    Text(activeRegion == nil
                        ? "Wähle eine Aktion oder stelle unten eine eigene Frage."
                        : "Die nächste Frage bezieht sich auf den markierten Bereich.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
                .padding(.vertical, 6)
            }

            Section {
                Button(action: presentExercise) {
                    actionLabel(
                        "Aufgabe lösen",
                        detail: "Aufgabennummer eingeben",
                        symbol: "function"
                    )
                }
                .foregroundStyle(.primary)
                .disabled(!canAsk)

                if showingExercise {
                    exerciseEditor
                        .listRowSeparator(.hidden)
                }

                actionButton(
                    "Seite erklären",
                    detail: "Kernaussage, Begriffe und Zusammenhänge",
                    symbol: "text.book.closed",
                    request: BookAIPrompts.explainPage
                )
                actionButton(
                    "Kurz zusammenfassen",
                    detail: "Das Wichtigste auf einen Blick",
                    symbol: "text.alignleft",
                    request: BookAIPrompts.summarizePage
                )
                actionButton(
                    "Abbildung erklären",
                    detail: "Darstellung lesen und einordnen",
                    symbol: "photo",
                    request: BookAIPrompts.explainFigure
                )
            }

            Section {
                Button {
                    requestRegion()
                } label: {
                    actionLabel(
                        activeRegion == nil ? "Bereich markieren" : "Anderen Bereich markieren",
                        detail: "Mit Finger oder Apple Pencil auswählen",
                        symbol: "rectangle.dashed"
                    )
                }
                .foregroundStyle(.primary)

                if activeRegion != nil {
                    Button {
                        useCurrentPage()
                    } label: {
                        actionLabel(
                            "Ganze Seite verwenden",
                            detail: "Markierung für die nächste Frage aufheben",
                            symbol: "doc"
                        )
                    }
                    .foregroundStyle(.primary)
                }
            }

            if !model.connectivity.isOnline {
                Section {
                    Label(
                        "Fragen benötigen eine Serververbindung. Das Buch bleibt verfügbar.",
                        systemImage: "wifi.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
    }

    private func actionButton(
        _ title: String,
        detail: String,
        symbol: String,
        request: String
    ) -> some View {
        Button {
            send(title, request: request)
        } label: {
            actionLabel(title, detail: detail, symbol: symbol)
        }
        .foregroundStyle(.primary)
        .disabled(!canAsk)
    }

    private func actionLabel(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var exerciseEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Aufgabe lösen", systemImage: "function")
                    .font(.headline)
                Spacer()
                Button("Abbrechen", systemImage: "xmark", action: dismissExercise)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Schließt die Aufgabeneingabe")
            }

            Text("Gib die Nummer der Aufgabe auf \(contextLabel.lowercased()) ein.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("z. B. 4b", text: $exerciseNumber)
                    .focused($exerciseFocused)
                    .submitLabel(.send)
                    .onSubmit(sendExercise)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(
                        Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                Button("Lösen", systemImage: "arrow.up", action: sendExercise)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(exerciseNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canAsk)
            }
        }
        .padding(14)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Conversation

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(store.turns) { turn in
                        exchange(turn)
                            .id(turn.id)
                    }
                    if showingExercise {
                        exerciseEditor
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
            .background(Color(.systemBackground))
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.turns.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store.sending) { _, _ in scrollToEnd(proxy) }
            .onChange(of: showingExercise) { _, visible in
                guard visible else { return }
                DispatchQueue.main.async { scrollToEnd(proxy) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func exchange(_ turn: BookAIStore.Turn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.question)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Label("Echo", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            BookAIAnswerView(text: turn.text)

            let citations = sources(for: turn)
            if !citations.isEmpty {
                citationDisclosure(turn, citations: citations)
            }

            responseActions(turn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func citationDisclosure(
        _ turn: BookAIStore.Turn,
        citations: [BackendAPI.BookCitation]
    ) -> some View {
        DisclosureGroup(isExpanded: citationBinding(for: turn.id)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(citations) { citation in
                    Button {
                        citationDestination = visiblePages.contains(citation.pdfPage) ? nil : citation.pdfPage
                        detent = .medium
                        goToPage(citation.pdfPage)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(numbering.citationLabel(pdfPage: citation.pdfPage))
                                    .font(.subheadline.weight(.medium))
                                if !citation.note.isEmpty {
                                    Text(citation.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
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
            .padding(.top, 6)
        } label: {
            Label(citationSummary(citations), systemImage: "text.book.closed")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
        }
    }

    private func citationBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedCitations.contains(id) },
            set: { expanded in
                withAnimation(reduceMotion ? nil : .default) {
                    if expanded { expandedCitations.insert(id) } else { expandedCitations.remove(id) }
                }
            }
        )
    }

    private func citationSummary(_ citations: [BackendAPI.BookCitation]) -> String {
        let pages = citations.map { numbering.citationLabel(pdfPage: $0.pdfPage) }
        return "\(citations.count) \(citations.count == 1 ? "Quelle" : "Quellen"): \(pages.joined(separator: ", "))"
    }

    /// Older servers may return only `pages_read`; keep those pages useful and
    /// prefer the richer citation note when both describe the same page.
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
                copiedTurn = turn.id
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedTurn == turn.id { copiedTurn = nil }
                }
            } label: {
                Image(systemName: copiedTurn == turn.id ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(copiedTurn == turn.id ? "Antwort kopiert" : "Antwort kopieren")

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
                        "Kürzer erklären",
                        bookID: bookID,
                        api: api,
                        request: BookAIPrompts.shorterFollowUp,
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
        .sensoryFeedback(.success, trigger: copiedTurn)
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
                    ? "Analysiert Seite \(pageLabel)…"
                    : "Analysiert den markierten Bereich…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Stoppen") { store.cancel() }
                    .font(.caption)
                    .frame(minHeight: 44)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            if store.lastFailed != nil, model.connectivity.isOnline {
                Button("Erneut versuchen") {
                    store.retryLastFailure(bookID: bookID, api: api)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.connectivity.isOnline {
                Label("Ohne Serververbindung — Lesen geht weiter, Fragen nicht.", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu {
                Button("Aktuelle Seite", systemImage: "doc", action: useCurrentPage)
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
                .frame(minHeight: 36)
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
                    .background(Color(.tertiarySystemFill), in: Capsule())

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
        .padding(.top, 7)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var followUps: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                followUp("Einfacher", BookAIPrompts.simplerFollowUp)
                followUp("Beispiel", BookAIPrompts.exampleFollowUp)
                followUp("Schritt für Schritt", BookAIPrompts.stepsFollowUp)
                followUp("Warum?", BookAIPrompts.whyFollowUp)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func followUp(_ label: String, _ request: String) -> some View {
        Button(label) { send(label, request: request) }
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

    private var canSend: Bool { store.canSend && canAsk }

    private func send(_ question: String, request: String? = nil) {
        guard canAsk else { return }
        inputFocused = false
        exerciseFocused = false
        withAnimation(reduceMotion ? nil : .default) {
            showingExercise = false
            detent = .large
        }
        store.ask(question, bookID: bookID, api: api, request: request)
    }

    private func sendDraft() {
        guard canSend else { return }
        send(store.draft)
    }

    private func sendExercise() {
        let number = exerciseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, canAsk else { return }
        exerciseNumber = ""
        send("Aufgabe \(number) lösen", request: BookAIPrompts.solveExercise(number))
    }

    private func presentExercise() {
        guard canAsk else { return }
        exerciseNumber = ""
        withAnimation(reduceMotion ? nil : .snappy) {
            showingExercise = true
            detent = .large
        }
        DispatchQueue.main.async { exerciseFocused = true }
    }

    private func dismissExercise() {
        exerciseFocused = false
        withAnimation(reduceMotion ? nil : .snappy) {
            showingExercise = false
        }
    }

    private func useCurrentPage() {
        citationDestination = nil
        let pageContext = BookAIStore.Context(pages: visiblePages)
        scopedContext = pageContext
        store.activate(pageContext)
        clearRegion()
    }
}

/// Kept alive while the panel is presented; recreating the synthesizer on
/// every redraw can swallow the beginning of an utterance.
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
