import SwiftUI

/// "Chat mit KI": free-form questions to Gemini, grounded in the running
/// recording or a picked past lesson (mockup screen 2).
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

    /// While recording, the chat is always grounded in the live transcript;
    /// when recording stops, fall back to context-free.
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
            ContentUnavailableView {
                Label("Frag alles, was du wissen willst", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Antworten nutzen das Transkript der laufenden Aufnahme oder einer ausgewählten Stunde.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(chat.messages) { message in
                            MessageRow(message: message)
                        }
                        if chat.sending {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Denkt nach…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                        Color.clear.frame(height: 2).id("chat-bottom")
                    }
                    .frame(maxWidth: Theme.Width.readable)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Space.screen)
                    .padding(.top, Theme.Space.screen)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.count) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 8) {
            composerStatus

            VStack(alignment: .leading, spacing: showsComposerTools ? 4 : 0) {
                if showsComposerTools {
                    contextChip
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Stelle eine Frage zum Unterricht…", text: $draft, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .focused($inputFocused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.leading, 8)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
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
            }
            .padding(6)
            .floatingComposerSurface(cornerRadius: inputFocused ? 22 : 28)
            .animation(reduceMotion ? nil : .snappy, value: showsComposerTools)
        }
        .frame(maxWidth: Theme.Width.readable)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.screen)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var showsComposerTools: Bool {
        inputFocused || chat.context != .none
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

    @ViewBuilder
    private var contextChip: some View {
        HStack(spacing: 6) {
            if model.phase == .recording {
                Label("Aktuelle Aufnahme", systemImage: "record.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
            } else {
                Menu {
                    Button("Ohne Kontext") { chat.context = .none }
                    ForEach(lessons) { lesson in
                        Button(title(for: lesson)) {
                            chat.context = .lesson(id: lesson.id, title: title(for: lesson))
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "text.book.closed")
                        Text(chat.context.label)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 36)
                }
                .accessibilityLabel("Kontext: \(chat.context.label)")
            }
            Spacer()
        }
        .padding(.horizontal, 8)
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

/// Conversation hierarchy borrowed from Messages: the student's words are a
/// compact colored bubble, while Echo's answer is reading content on the page.
/// Both get quiet metadata below rather than carrying controls inside the text.
private struct MessageRow: View {
    let message: ChatStore.Message

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 2) {
                Text(renderedMarkdown(message.text))
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Theme.accent,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .frame(maxWidth: Theme.Width.readable * 0.85, alignment: .trailing)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadata(copyLabel: String) -> some View {
        HStack(spacing: 2) {
            if message.role == .user { Spacer(minLength: 0) }
            CopyFeedbackButton(text: message.text, accessibilityLabel: copyLabel)
            Text(message.date.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            if message.role == .assistant { Spacer(minLength: 0) }
        }
    }
}

/// A failure or offline state belongs to the action it prevents. Keeping this
/// pill directly above the composer leaves the conversation itself undisturbed.
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
