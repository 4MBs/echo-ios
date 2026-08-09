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
/// It is built out of the system's own parts — a navigation bar with its
/// inline title and toolbar, grouped-background surfaces, `Capsule` tokens for
/// what has been picked, and the same round `arrow.up.circle.fill` send button
/// Messages uses — so that it reads as part of iPadOS rather than as a panel
/// with its own ideas.
struct BookAIPanel: View {
    @Environment(AppModel.self) private var model

    let bookID: String
    let numbering: BookPageNumbering
    /// The PDF pages on screen right now — one page, or both of a spread.
    let visiblePages: [Int]
    let store: BookAIStore
    /// What the student has tapped in the book, in the order they tapped it.
    /// This is the question: nothing has to be typed to send it.
    let selectedTasks: [BookPageTask]
    /// What to say about tapping — a book the server has not read yet has
    /// nothing to tap, and saying so beats leaving the page looking dead.
    let tapHint: String
    /// Put one picked block back.
    let unpick: (BookPageTask) -> Void
    /// Put all of them back.
    let clearTasks: () -> Void
    /// Turn the book to a PDF page (a tapped citation).
    let goToPage: (Int) -> Void
    /// nil in the sheet, where the sheet's own dismissal is the way out.
    let close: (() -> Void)?

    @FocusState private var inputFocused: Bool

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Buch-KI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text("Buch-KI").font(.headline)
                // What the answer will be about, said the way the reader says
                // it: the printed page number, not the PDF page sent up.
                Text("Seite \(numbering.printedLabel(forVisible: visiblePages))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Antwort leeren", systemImage: "eraser") { store.clear() }
                    .disabled(store.exchange == nil && store.errorMessage == nil)
                Button("Auswahl aufheben", systemImage: "rectangle.dashed") { clearTasks() }
                    .disabled(selectedTasks.isEmpty)
            } label: {
                // the same glyph the reader's own menu uses, one bar over
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Mehr")
        }
        if let close {
            ToolbarItem(placement: .topBarLeading) {
                Button("Fertig", action: close)
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let exchange = store.exchange {
                    answer(exchange)
                } else if store.sending {
                    working
                } else if let error = store.errorMessage {
                    failure(error)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
    }

    private var working: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Liest im Buch…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answer(_ exchange: BookAIStore.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Turning the page while an answer is up must not make it look
            // like the answer is about the page now on screen.
            if exchange.pages != visiblePages {
                Label(
                    "Zu Seite \(numbering.printedLabel(forVisible: exchange.pages))",
                    systemImage: "text.book.closed"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(exchange.question)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(exchange.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !exchange.citations.isEmpty {
                citations(exchange.citations)
            }
        }
        .padding(16)
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
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failed = store.lastFailed, model.connectivity.isOnline {
                Button("Erneut versuchen") {
                    Task { await store.ask(failed.question, pages: failed.pages, bookID: bookID, api: api) }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: Theme.Radius.surface)
    }

    /// Nothing asked yet: say how tapping works, then offer the four things a
    /// schoolbook page is usually about. They fill the field rather than
    /// sending, so the question can still be aimed before it goes.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 18) {
            ContentUnavailableView {
                Label("Frag zu dieser Seite", systemImage: "sparkles")
            } description: {
                Text(tapHint)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Vorschläge")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(Self.prompts) { prompt in
                    Button {
                        store.draft = prompt.text
                        inputFocused = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: prompt.symbol)
                                .font(.subheadline)
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                            Text(prompt.label)
                                .font(.subheadline)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface(cornerRadius: Theme.Radius.control)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private struct Prompt: Identifiable {
        let label: String
        let symbol: String
        let text: String

        var id: String { label }
    }

    private static let prompts: [Prompt] = [
        Prompt(label: "Seite erklären", symbol: "text.book.closed", text: "Erkläre diese Seite verständlich."),
        Prompt(
            label: "Aufgaben lösen",
            symbol: "function",
            text: "Löse die Aufgaben auf dieser Seite Schritt für Schritt."
        ),
        Prompt(
            label: "Zusammenfassen",
            symbol: "list.bullet.rectangle",
            text: "Fasse diese Seite in wenigen Sätzen zusammen."
        ),
        Prompt(label: "Abbildung erklären", symbol: "photo", text: "Erkläre die Abbildung auf dieser Seite."),
    ]

    // MARK: - Input

    @ViewBuilder
    private var inputBar: some View {
        // the field writes straight into the store, so a half-typed question
        // survives the panel being scrolled or the answer arriving
        @Bindable var store = self.store
        VStack(alignment: .leading, spacing: 10) {
            if !model.connectivity.isOnline {
                Label("Ohne Serververbindung — Lesen geht weiter, Fragen nicht.", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !selectedTasks.isEmpty {
                pickedTokens
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
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel("Frage senden")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
    }

    /// What the student has picked, as tokens — the shape iOS uses for
    /// something you have added and can take back out again, as in Mail's
    /// address field. They wrap, because a page can carry several exercises
    /// and they should not push the field off screen.
    private var pickedTokens: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(selectedTasks.count == 1 ? "1 ausgewählt" : "\(selectedTasks.count) ausgewählt")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Alle aufheben", action: clearTasks)
                    .font(.footnote)
            }
            WrappingRow(spacing: 6) {
                ForEach(selectedTasks) { task in
                    Button {
                        unpick(task)
                    } label: {
                        HStack(spacing: 5) {
                            Text(task.labelText)
                                .font(.footnote)
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.leading, 11)
                        .padding(.trailing, 9)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(task.labelText) abwählen")
                }
            }
        }
    }

    /// With something picked the field is optional, and says so.
    private var fieldPrompt: String {
        selectedTasks.isEmpty ? "Frage zu dieser Seite…" : "Noch etwas dazu? (optional)"
    }

    private var canSend: Bool {
        let hasQuestion = store.canSend || (!selectedTasks.isEmpty && !store.sending)
        return hasQuestion && model.connectivity.isOnline && !visiblePages.isEmpty
    }

    private func send() {
        guard canSend else { return }
        // What is picked IS the question; anything typed alongside is an
        // addition to it, not a replacement.
        let question = selectedTasks.isEmpty
            ? store.draft
            : BookPageTask.question(for: selectedTasks, note: store.draft)
        inputFocused = false
        clearTasks()
        Task { await store.ask(question, pages: visiblePages, bookID: bookID, api: api) }
    }
}

/// Lays its children out in rows, wrapping when one runs out of width — what
/// tokens need and what `HStack` will not do.
private struct WrappingRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalWidth = subviews.reduce(CGFloat.zero) { result, subview in
            result + subview.sizeThatFits(.unspecified).width
        } + spacing * CGFloat(max(subviews.count - 1, 0))
        let proposedWidth = proposal.width ?? naturalWidth
        let width = proposedWidth.isFinite && proposedWidth > 0 ? proposedWidth : naturalWidth
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, x + size.width > width {
                rows.append(row)
                row = Row()
                x = 0
            }
            row.indices.append(index)
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
