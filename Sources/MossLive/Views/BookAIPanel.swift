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
struct BookAIPanel: View {
    @Environment(AppModel.self) private var model

    let bookID: String
    let bookTitle: String
    let numbering: BookPageNumbering
    /// The PDF pages on screen right now — one page, or both of a spread.
    let visiblePages: [Int]
    let store: BookAIStore
    /// The exercise tapped in the book, if one is picked. It is the question:
    /// nothing has to be typed to send it.
    let selectedTask: BookPageTask?
    /// Put the picked exercise back.
    let clearTask: () -> Void
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
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            inputBar
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Buch-KI")
                    .font(.headline)
                // What the answer will be about, said the way the reader says
                // it: the printed page number, not the PDF page sent to the
                // server.
                Text("\(bookTitle) · Seite \(numbering.printedLabel(forVisible: visiblePages))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if store.exchange != nil || store.errorMessage != nil {
                Button("Leeren") { store.clear() }
                    .font(.footnote)
            }
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Buch-KI schließen")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
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
                    suggestions
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
                .font(.subheadline.weight(.medium))
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(list) { citation in
                Button {
                    goToPage(citation.pdfPage)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
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
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
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

    /// Four openings for the four things a schoolbook page is usually about.
    /// They fill the field rather than sending straight away, so the question
    /// can still be aimed at one exercise before it goes.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fragen zu dieser Seite — die KI liest sie auf dem Server, samt Abbildungen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Tippe im Buch direkt auf eine Aufgabe — sie wird ausgewählt und du kannst sie "
                    + "gleich abschicken.",
                systemImage: "hand.tap"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.prompts) { prompt in
                Button {
                    store.draft = prompt.text
                    inputFocused = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: prompt.symbol)
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20)
                        Text(prompt.label)
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface(cornerRadius: Theme.Radius.control)
                }
                .buttonStyle(.plain)
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
            label: "Aufgabe lösen",
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
        VStack(alignment: .leading, spacing: 8) {
            if !model.connectivity.isOnline {
                Label("Ohne Serververbindung — Lesen geht weiter, Fragen nicht.", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let task = selectedTask {
                taskChip(task)
            }
            HStack(spacing: 10) {
                TextField(fieldPrompt, text: $store.draft, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .cardSurface(cornerRadius: 22)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Theme.accent : Color.secondary.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Frage senden")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
    }

    /// The picked exercise, shown the way the page shows it — number first,
    /// then as much of the wording as fits. Tapping it in the book again, or
    /// the cross here, puts it back.
    private func taskChip(_ task: BookPageTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .font(.caption)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(task.label) · Seite \(numbering.printedLabel(task.pdfPage))")
                    .font(.footnote.weight(.semibold))
                if !task.text.isEmpty {
                    Text(task.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button(action: clearTask) {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Aufgabe abwählen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.control)
    }

    /// With an exercise picked the field is optional, and says so.
    private var fieldPrompt: String {
        selectedTask == nil ? "Frage zu dieser Seite…" : "Noch etwas dazu? (optional)"
    }

    private var canSend: Bool {
        let hasQuestion = store.canSend || (selectedTask != nil && !store.sending)
        return hasQuestion && model.connectivity.isOnline && !visiblePages.isEmpty
    }

    private func send() {
        guard canSend else { return }
        // A picked exercise IS the question; anything typed alongside it is an
        // addition to it, not a replacement.
        let question = selectedTask.map { $0.question(note: store.draft) } ?? store.draft
        inputFocused = false
        clearTask()
        Task { await store.ask(question, pages: visiblePages, bookID: bookID, api: api) }
    }
}
