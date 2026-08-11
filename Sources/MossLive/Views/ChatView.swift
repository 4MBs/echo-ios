import SwiftUI

/// Free-form questions grounded in the running recording or a picked lesson.
/// Its conversation and composer intentionally follow T3 Code mobile's thread
/// presentation so all emphasis stays on what the assistant actually said.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = ""
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @FocusState private var inputFocused: Bool

    private var chat: ChatStore { model.chat }

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    var body: some View {
        NavigationStack {
            messagesArea
                .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
                .groupedScreen()
                .navigationTitle("Chat mit KI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if !chat.messages.isEmpty {
                            Menu {
                                Button("Chat leeren", systemImage: "eraser", role: .destructive) {
                                    chat.clear()
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .accessibilityLabel("Chatoptionen")
                        }
                    }
                }
        }
        .task { await loadLessons() }
        .onAppear { syncContextWithRecording() }
        .onChange(of: model.phase) { syncContextWithRecording() }
    }

    private func syncContextWithRecording() {
        if model.phase == .recording {
            chat.context = .live
        } else if chat.context == .live {
            chat.context = .none
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private var messagesArea: some View {
        if chat.messages.isEmpty {
            VStack(spacing: 8) {
                Text("Noch keine Unterhaltung")
                    .font(.headline.weight(.bold))
                Text("Frag etwas zur laufenden Aufnahme, zu einer vergangenen Stunde oder ganz ohne Kontext.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
        } else {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Theme.Conversation.turnSpacing) {
                            ForEach(chat.messages) { message in
                                MessageRow(message: message)
                            }
                            if chat.sending {
                                ConversationThinkingDots()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 2).id("chat-bottom")
                        }
                        .frame(maxWidth: Theme.Width.readable)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height,
                            alignment: .bottom
                        )
                        .padding(.horizontal, Theme.Space.screen)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.messages.count) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Input

    /// Echo only needs one context selector, so it stays inside T3's compact
    /// composer rather than expanding into an 174pt agent toolbar on focus.
    private var inputBar: some View {
        VStack(spacing: 8) {
            composerStatus

            HStack(alignment: .bottom, spacing: 6) {
                contextControl
                TextField("Stelle eine Frage zum Unterricht…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.vertical, 9)
                    .frame(minHeight: 44, maxHeight: 96, alignment: .leading)
                sendButton
            }
            .padding(5)
            .floatingComposerSurface(cornerRadius: 28)
        }
        .frame(maxWidth: Theme.Width.readable)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(ConversationPrimaryButtonStyle())
        .disabled(!canSend)
        .accessibilityLabel("Frage senden")
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

    @ViewBuilder
    private var composerStatus: some View {
        if let error = chat.errorMessage {
            ChatStatusPill(error, systemImage: "exclamationmark.triangle.fill", tint: .red)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !model.connectivity.isOnline {
            ChatStatusPill(
                "Offline — Senden ist wieder möglich, sobald der Server erreichbar ist.",
                systemImage: "wifi.slash"
            )
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var contextControl: some View {
        if model.phase == .recording {
            Image(systemName: "record.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Kontext: Aktuelle Aufnahme")
        } else {
            Menu {
                Button("Ohne Kontext") { chat.context = .none }
                ForEach(lessons) { lesson in
                    Button(title(for: lesson)) {
                        chat.context = .lesson(id: lesson.id, title: title(for: lesson))
                    }
                }
            } label: {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Kontext: \(chat.context.label)")
        }
    }

    private func title(for lesson: BackendAPI.LessonInfo) -> String {
        lesson.title ?? lesson.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadLessons() async {
        if let stored = OfflineCache.load([BackendAPI.LessonInfo].self, key: OfflineCache.Key.lessons) {
            lessons = stored
        }
        guard let fresh = try? await api.listLessons().filter({ $0.segmentCount > 0 }) else { return }
        lessons = fresh
        OfflineCache.save(fresh, as: OfflineCache.Key.lessons)
    }
}

/// T3 Code's conversation hierarchy: an 85%-width system-blue user bubble,
/// unboxed assistant prose, and copy/time metadata outside the content.
private struct MessageRow: View {
    let message: ChatStore.Message

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 2) {
                Text(renderedMarkdown(message.text))
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Conversation.userHorizontalInset)
                    .padding(.vertical, Theme.Conversation.userVerticalInset)
                    .background(
                        Color(.systemBlue),
                        in: RoundedRectangle(
                            cornerRadius: Theme.Conversation.userBubbleRadius,
                            style: .continuous
                        )
                    )
                    .frame(
                        maxWidth: Theme.Width.readable * Theme.Conversation.userBubbleWidth,
                        alignment: .trailing
                    )
                metadata(copyLabel: "Frage kopieren")
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(renderedMarkdown(message.text))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                metadata(copyLabel: "Antwort kopieren")
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadata(copyLabel: String) -> some View {
        HStack(spacing: 2) {
            if message.role == .user {
                Spacer(minLength: 0)
                timestamp
                CopyFeedbackButton(text: message.text, accessibilityLabel: copyLabel)
            } else {
                CopyFeedbackButton(text: message.text, accessibilityLabel: copyLabel)
                timestamp
                Spacer(minLength: 0)
            }
        }
    }

    private var timestamp: some View {
        Text(message.date.formatted(date: .omitted, time: .shortened))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
    }
}

private struct ChatStatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(_ text: String, systemImage: String, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
