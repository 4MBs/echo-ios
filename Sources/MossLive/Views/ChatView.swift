import SwiftUI
import UIKit

/// "Chat mit KI": free-form questions to Gemini, grounded in the running
/// recording or a picked past lesson.
///
/// Assembled out of stock parts wherever one exists. The send button is the
/// system's own bordered-prominent button in a circle rather than a hand-drawn
/// disc, so its pressed and disabled states come from iOS instead of being
/// guessed. Copying a reply is a long-press, which is where iOS users look for
/// it. And the composer is a bottom safe-area inset, so the thread scrolls
/// underneath it the way Nachrichten does.
struct ChatView: View {
    @Environment(AppModel.self) private var model

    @State private var draft = ""
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var confirmingClear = false
    @FocusState private var inputFocused: Bool

    private static let bottomAnchor = "chat-bottom"

    private var chat: ChatStore { model.chat }

    private var api: BackendAPI { model.api }

    var body: some View {
        NavigationStack {
            messagesArea
                .groupedScreen()
                .navigationTitle("Chat mit KI")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if !chat.messages.isEmpty {
                            Button("Leeren", role: .destructive) { confirmingClear = true }
                        }
                    }
                }
                .confirmationDialog(
                    "Unterhaltung leeren?",
                    isPresented: $confirmingClear,
                    titleVisibility: .visible
                ) {
                    Button("Leeren", role: .destructive) { chat.clear() }
                    Button("Abbrechen", role: .cancel) {}
                }
        }
        .task { await loadLessons() }
        .onAppear { syncContextWithRecording() }
        .onChange(of: model.phase) { syncContextWithRecording() }
    }

    /// While recording, the chat is always grounded in the live transcript;
    /// when recording stops, fall back to context-free.
    private func syncContextWithRecording() {
        if model.phase == .recording {
            chat.context = .live
        } else if chat.context == .live {
            chat.context = .none
        }
    }

    // MARK: - Thread

    @ViewBuilder
    private var messagesArea: some View {
        if chat.messages.isEmpty {
            ContentUnavailableView {
                Label("Frag alles, was du wissen willst", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Antworten nutzen das Transkript der laufenden Aufnahme oder einer ausgewählten Stunde.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message)
                        }
                        if chat.sending {
                            ThinkingBubble()
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(16)
                }
                // Both stock: the thread opens at its end, and dragging it
                // puts the keyboard away without a "Fertig" button.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.count) { scrollToEnd(proxy) }
                .onChange(of: chat.sending) { scrollToEnd(proxy) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = chat.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            contextButton
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Stelle eine Frage zum Unterricht…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .cardSurface(cornerRadius: 20)
                // The system's button, not a circle drawn by hand: it brings
                // its own press animation and its own disabled treatment, and
                // the up arrow is the glyph iOS uses for sending a message.
                Button("Frage senden", systemImage: "arrow.up", action: send)
                    .labelStyle(.iconOnly)
                    .fontWeight(.semibold)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .disabled(!canSend)
                    .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chat.sending
            && model.connectivity.isOnline
    }

    private func send() {
        guard canSend else { return }
        let question = draft
        draft = ""
        Task { await chat.send(question: question, api: api) }
    }

    /// What the next question is grounded in. Locked to the live transcript
    /// while recording; otherwise a past lesson (or nothing) can be picked.
    ///
    /// A Picker inside the menu rather than loose buttons, so the current
    /// choice carries the system's checkmark instead of only being legible
    /// from the label outside.
    @ViewBuilder
    private var contextButton: some View {
        if model.phase == .recording {
            Label("Aktuelle Aufnahme", systemImage: "record.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
        } else {
            Menu {
                Picker("Kontext", selection: contextBinding) {
                    Text("Ohne Kontext").tag(ChatStore.Context.none)
                    ForEach(lessons) { lesson in
                        Text(title(for: lesson))
                            .tag(ChatStore.Context.lesson(id: lesson.id, title: title(for: lesson)))
                    }
                }
            } label: {
                Label(chat.context.label, systemImage: "text.book.closed")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }

    private var contextBinding: Binding<ChatStore.Context> {
        Binding(get: { chat.context }, set: { chat.context = $0 })
    }

    private func title(for lesson: BackendAPI.LessonInfo) -> String {
        lesson.title ?? lesson.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadLessons() async {
        // Only the picker's contents — the stored list keeps it populated so
        // an old chat still shows which lesson it was about.
        if let stored = OfflineCache.load([BackendAPI.LessonInfo].self, key: OfflineCache.Key.lessons) {
            lessons = stored
        }
        guard let fresh = try? await api.listLessons().filter({ $0.segmentCount > 0 }) else { return }
        lessons = fresh
        OfflineCache.save(fresh, as: OfflineCache.Key.lessons)
    }
}

/// One turn. No avatar on every reply: Nachrichten does not repeat one, and
/// with two participants the side of the screen already says who is speaking.
/// Copy and share are a long-press, which is where iOS keeps them.
private struct MessageBubble: View {
    let message: ChatStore.Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 48) }
            Text(renderedMarkdown(message.text))
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUser
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .contextMenu {
                    Button("Kopieren", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = message.text
                    }
                    ShareLink(item: message.text)
                }
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

/// The wait, shaped like the reply it is about to become.
private struct ThinkingBubble: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Denkt nach…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}
