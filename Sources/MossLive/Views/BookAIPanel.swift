import SwiftUI
import UIKit

/// A page-scoped conversation presented by the book reader's adaptive
/// inspector. It deliberately uses the same thread and composer language as
/// the main Chat tab; the page or marked region is its fixed context.
struct BookAIPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let bookID: String
    let numbering: BookPageNumbering
    let visiblePages: [Int]
    let region: BackendAPI.BookPageRegion?
    let store: BookAIStore
    @Binding var detent: PresentationDetent
    let goToPage: (Int) -> Void
    let requestRegion: () -> Void
    let clearRegion: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var expandedCitations: Set<UUID> = []
    @State private var copiedTurn: UUID?
    @State private var scopedContext: BookAIStore.Context?
    @State private var citationDestination: Int?
    @State private var dictationPrefix = ""
    @State private var voiceError: String?
    @State private var voiceInput = ChatVoiceInput()

    private static let bottomID = "book-chat-bottom"

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
            messagesArea
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .background(Color(.systemBackground).ignoresSafeArea())
                .navigationTitle(contextLabel)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .onAppear {
            scopedContext = incomingContext
            store.activate(incomingContext)
        }
        .onDisappear { voiceInput.stop() }
        .onChange(of: incomingContext) { _, newContext in
            guard citationDestination == nil else { return }
            scopedContext = newContext
            store.activate(newContext)
        }
        .onChange(of: visiblePages) { _, pages in
            guard let destination = citationDestination, pages.contains(destination) else { return }
            citationDestination = nil
        }
        .onChange(of: voiceInput.transcript) { _, transcript in
            guard !transcript.isEmpty else { return }
            store.draft = dictationPrefix + transcript
        }
        .onChange(of: voiceInput.errorMessage) { _, error in
            if let error { voiceError = error }
        }
    }

    // MARK: - Navigation

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if store.hasConversation {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.clear()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Neue Unterhaltung")

                Menu {
                    Button("Unterhaltung leeren", systemImage: "eraser", role: .destructive) {
                        store.clear()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Chatoptionen")
            }
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private var messagesArea: some View {
        if store.turns.isEmpty, store.pending == nil {
            VStack {
                Text("Unterhaltung beginnen")
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 72)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(Array(store.turns.enumerated()), id: \.element.id) { index, turn in
                            exchange(
                                turn,
                                isLast: index == store.turns.count - 1
                            )
                            .id(turn.id)
                        }
                        if let pending = store.pending {
                            userBubble(pending.question)
                        }
                        if store.sending {
                            ChatThinkingIndicator()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.turns.count) { scrollToBottom(proxy) }
                .onChange(of: store.sending) { scrollToBottom(proxy) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func exchange(_ turn: BookAIStore.Turn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            userBubble(turn.question)
            assistantMessage(turn, isLast: isLast)
        }
    }

    private func userBubble(_ text: String) -> some View {
        Text(renderedMarkdown(text))
            .font(.body)
            .lineSpacing(3)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 640, alignment: .trailing)
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Kopieren", systemImage: "doc.on.doc")
                }
            }
    }

    private func assistantMessage(_ turn: BookAIStore.Turn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(renderedMarkdown(turn.text))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            let citations = sources(for: turn)
            if !citations.isEmpty {
                citationDisclosure(turn, citations: citations)
            }

            HStack(spacing: 4) {
                Button {
                    copy(turn)
                } label: {
                    Image(systemName: copiedTurn == turn.id ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(copiedTurn == turn.id ? "Kopiert" : "Antwort kopieren")

                if isLast, !store.sending {
                    Button {
                        store.retry(turn, bookID: bookID, api: api)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Antwort neu erstellen")
                }
                Spacer()
            }

            if isLast {
                Text("KI kann Fehler machen. Prüfe wichtige Informationen.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ turn: BookAIStore.Turn) {
        UIPasteboard.general.string = turn.text
        withAnimation { copiedTurn = turn.id }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedTurn == turn.id {
                withAnimation { copiedTurn = nil }
            }
        }
    }

    // MARK: - Citations

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
                    if expanded {
                        expandedCitations.insert(id)
                    } else {
                        expandedCitations.remove(id)
                    }
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

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 7) {
            composerStatus

            VStack(spacing: 0) {
                TextField(
                    store.turns.isEmpty ? "Was möchtest du wissen?" : "Nachricht",
                    text: draftBinding,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1 ... 5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 10)
                .frame(minHeight: 62, maxHeight: 142, alignment: .topLeading)

                HStack(spacing: 10) {
                    contextMenu

                    Spacer(minLength: 0)

                    Button {
                        if voiceInput.isRecording {
                            voiceInput.stop()
                        } else {
                            voiceError = nil
                            dictationPrefix = store.draft.isEmpty ? "" : store.draft + " "
                            Task { await voiceInput.start() }
                        }
                    } label: {
                        ZStack {
                            if voiceInput.isRecording {
                                Circle()
                                    .fill(.red.opacity(0.16))
                                    .frame(width: 38, height: 38)
                            }
                            Image(systemName: voiceInput.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 19))
                                .foregroundStyle(voiceInput.isRecording ? .red : .secondary)
                                .frame(width: 30, height: 30)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.sending || model.phase == .recording)
                    .accessibilityLabel(voiceInput.isRecording ? "Diktat beenden" : "Frage diktieren")

                    Button {
                        if store.sending { store.cancel() } else { sendDraft() }
                    } label: {
                        Image(systemName: store.sending ? "stop.fill" : "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .disabled(!store.sending && !canSend)
                    .accessibilityLabel(store.sending ? "Antwort stoppen" : "Nachricht senden")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var contextMenu: some View {
        Menu {
            Button("Aktuelle Seite", systemImage: activeRegion == nil ? "checkmark" : "doc") {
                useCurrentPage()
            }
            .disabled(activeRegion == nil && context.pages == visiblePages)

            Button("Bereich markieren", systemImage: "rectangle.dashed") {
                requestRegion()
            }
        } label: {
            if activeRegion != nil {
                Label("Ausschnitt", systemImage: "rectangle.dashed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            } else {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
        }
        .accessibilityLabel("Kontext: \(contextLabel)")
    }

    @ViewBuilder
    private var composerStatus: some View {
        if let error = voiceError ?? store.errorMessage {
            ChatStatusPill(error, systemImage: "exclamationmark.triangle.fill", tint: .red)
        } else if !model.connectivity.isOnline {
            ChatStatusPill("Offline — Senden ist gerade nicht möglich.", systemImage: "wifi.slash")
        }
    }

    private var draftBinding: Binding<String> {
        Binding(get: { store.draft }, set: { store.draft = $0 })
    }

    private var canAsk: Bool {
        !store.sending && model.connectivity.isOnline && !context.pages.isEmpty
    }

    private var canSend: Bool { store.canSend && canAsk }

    private func sendDraft() {
        guard canSend else { return }
        voiceInput.stop()
        voiceError = nil
        inputFocused = false
        withAnimation(reduceMotion ? nil : .default) {
            detent = .large
        }
        store.ask(store.draft, bookID: bookID, api: api)
    }

    private func useCurrentPage() {
        citationDestination = nil
        let pageContext = BookAIStore.Context(pages: visiblePages)
        scopedContext = pageContext
        store.activate(pageContext)
        clearRegion()
    }
}
