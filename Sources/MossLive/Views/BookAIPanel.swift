import SwiftUI

/// Buch-KI, next to the open book: ask about the page you are looking at.
///
/// On an iPad it is a trailing panel and the book stays open beside it, which
/// is the whole point — the answer is read against the page it is about. On a
/// phone there is no room for both, so the reader presents this as a sheet.
///
/// The panel sends the question and the PDF pages on screen, nothing else: the
/// server has the book. What comes back is an answer plus the pages it rests
/// on, and those are buttons — tapping one turns the book to that page.
///
/// It is built out of the system's own parts — a navigation stack with an
/// inline title and a page subtitle, `ContentUnavailableView` before the first
/// question, capsule chips for the openings, and a glass send button — so it
/// reads as the same app as the reader beside it rather than as a panel with
/// its own ideas. Its bar mirrors the reader's: leave on the left, more on the
/// right.
struct BookAIPanel: View {
    @Environment(AppModel.self) private var model

    let bookID: String
    let numbering: BookPageNumbering
    /// The PDF pages on screen right now — one page, or both of a spread.
    let visiblePages: [Int]
    let store: BookAIStore
    /// Turn the book to a PDF page (a tapped citation).
    let goToPage: (Int) -> Void
    /// Close the panel — the side panel on an iPad, the sheet on a phone.
    let close: () -> Void

    @FocusState private var inputFocused: Bool

    /// Anchor the thread scrolls to when a turn arrives.
    private static let bottomID = "buch-ki-bottom"

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    private var pageLabel: String {
        numbering.printedLabel(forVisible: visiblePages)
    }

    var body: some View {
        NavigationStack {
            content
                .groupedScreen()
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .navigationTitle("Buch-KI")
                .navigationSubtitle("Seite \(pageLabel)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
    }

    // MARK: - Bar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Fertig", action: close)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Verlauf leeren", systemImage: "eraser") { store.clear() }
                    .disabled(!store.hasContent)
            } label: {
                // the same glyph the reader's own menu uses, one bar over
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Mehr")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.turns.isEmpty, store.pending == nil, store.errorMessage == nil {
            empty
        } else {
            thread
        }
    }

    /// Before the first question: say what the thing is for, in the same shape
    /// the shelf uses when it has no books.
    private var empty: some View {
        ContentUnavailableView {
            Label("Frag zu dieser Seite", systemImage: "sparkles")
        } description: {
            Text(emptyDescription)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDescription: String {
        "Die KI liest Seite \(pageLabel) auf dem Server — samt Abbildungen — und sagt dazu, worauf sie sich stützt."
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.inset) {
                    ForEach(store.turns) { turn in
                        answer(turn)
                            .id(turn.id)
                    }
                    if let pending = store.pending {
                        working(pending.question)
                    }
                    if let error = store.errorMessage {
                        failure(error)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.inset)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.turns.count) { scrollToEnd(proxy) }
            .onChange(of: store.sending) { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    /// The question is on screen while it is being answered, so a follow-up
    /// never leaves the panel looking like it forgot what was asked.
    private func working(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            Text(question)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Liest im Buch…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.surface)
    }

    private func answer(_ turn: BookAIStore.Turn) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            // Turning the page while an answer is up must not make it look
            // like the answer is about the page now on screen.
            if turn.pages != visiblePages {
                Label(
                    "Zu Seite \(numbering.printedLabel(forVisible: turn.pages))",
                    systemImage: "text.book.closed"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(turn.question)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(renderedMarkdown(turn.text))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !turn.citations.isEmpty {
                citations(turn.citations)
            }
        }
        .padding(Theme.Space.inset)
        .cardSurface(cornerRadius: Theme.Radius.surface)
    }

    /// The pages the answer came from, attached to it and tappable. Named with
    /// the printed numbers the student reads off the paper, but each one turns
    /// the book to the PDF page the server actually cited.
    private func citations(_ list: [BackendAPI.BookCitation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Quellen im Buch")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(list) { citation in
                Button {
                    goToPage(citation.pdfPage)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.book.closed")
                            .font(.footnote)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(numbering.citationLabel(pdfPage: citation.pdfPage))
                                .font(.subheadline)
                            if !citation.note.isEmpty {
                                Text(citation.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.forward")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!numbering.contains(pdfPage: citation.pdfPage))
                .accessibilityHint("Öffnet diese Seite im Buch")
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failed = store.lastFailed, model.connectivity.isOnline {
                Button("Erneut versuchen") {
                    Task { await store.ask(failed.question, pages: failed.pages, bookID: bookID, api: api) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(Theme.Space.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.surface)
    }

    // MARK: - Chips

    /// One tap, one question. A chip is a thing you say, not a thing you fill
    /// in — the only one that does not send is "Aufgabe …", where the point is
    /// that you finish the sentence with the number printed on the page.
    private struct Chip: Identifiable {
        let label: String
        let text: String
        /// Put the text in the field and wait, instead of sending it.
        var completes = false

        var id: String { label }
    }

    /// Openings for a page nothing has been asked about yet. Pointing at one
    /// exercise comes first: it is the most common thing a student wants and
    /// the one thing prose cannot do briefly.
    private static let starters: [Chip] = [
        Chip(label: "Aufgabe …", text: "Löse Aufgabe ", completes: true),
        Chip(label: "Seite erklären", text: "Erkläre diese Seite verständlich."),
        Chip(label: "Zusammenfassen", text: "Fasse diese Seite in wenigen Sätzen zusammen."),
        Chip(label: "Aufgaben lösen", text: "Löse die Aufgaben auf dieser Seite Schritt für Schritt."),
        Chip(label: "Abbildung erklären", text: "Erkläre die Abbildung auf dieser Seite."),
    ]

    /// What you say to an answer you have just read. These send: there is an
    /// answer above them, so what "das" refers to is not in doubt.
    private static let followUps: [Chip] = [
        Chip(label: "Einfacher erklären", text: "Erklär das nochmal einfacher."),
        Chip(label: "Schritt für Schritt", text: "Zeig den Rechenweg Schritt für Schritt."),
        Chip(label: "Beispiel geben", text: "Gib mir ein Beispiel dazu."),
        Chip(label: "Warum?", text: "Warum ist das so?"),
    ]

    private var chips: [Chip] {
        store.turns.isEmpty ? Self.starters : Self.followUps
    }

    private var chipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button(chip.label) { tap(chip) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(!canAsk)
                }
            }
            .padding(.horizontal, Theme.Space.inset)
        }
        .scrollIndicators(.hidden)
    }

    private func tap(_ chip: Chip) {
        if chip.completes {
            store.draft = chip.text
            inputFocused = true
        } else {
            Task { await store.ask(chip.text, pages: visiblePages, bookID: bookID, api: api) }
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        // the field writes straight into the store, so a half-typed question
        // survives the panel being scrolled or an answer arriving
        @Bindable var store = self.store
        VStack(alignment: .leading, spacing: 10) {
            if !model.connectivity.isOnline {
                Label("Ohne Serververbindung — Lesen geht weiter, Fragen nicht.", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.inset)
            }
            if !store.sending {
                chipRow
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(fieldPrompt, text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!canSend)
                .accessibilityLabel("Frage senden")
            }
            .padding(.horizontal, Theme.Space.inset)
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
    }

    /// The field says what the next question would be about, which is where a
    /// follow-up differs from a first question.
    private var fieldPrompt: String {
        store.turns.isEmpty ? "Frage zu Seite \(pageLabel)…" : "Nachfragen…"
    }

    /// Whether the server can be asked at all right now.
    private var canAsk: Bool {
        !store.sending && model.connectivity.isOnline && !visiblePages.isEmpty
    }

    private var canSend: Bool {
        store.canSend && canAsk
    }

    private func send() {
        guard canSend else { return }
        let question = store.draft
        inputFocused = false
        Task { await store.ask(question, pages: visiblePages, bookID: bookID, api: api) }
    }
}
