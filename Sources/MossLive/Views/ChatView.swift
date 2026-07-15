import SwiftUI
import UIKit

/// "Chat mit KI": free-form questions to Gemini, grounded in the running
/// recording or a picked past lesson (mockup screen 2).
struct ChatView: View {
    @Environment(AppModel.self) private var model

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
            VStack(spacing: 0) {
                messagesArea
                if let error = chat.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                inputBar
            }
            .background(PaperBackground())
            .navigationTitle("Chat mit KI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !chat.messages.isEmpty {
                        Button("Leeren") { chat.clear() }
                            .font(.footnote)
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
            VStack(spacing: 16) {
                Spacer()
                Text("Frag alles,\nwas du wissen willst!")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .stickyNote(rotation: 2)
                Text("Antworten nutzen das Transkript der laufenden Aufnahme\noder einer ausgewählten Stunde.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message)
                        }
                        if chat.sending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Denkt nach…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                        }
                        Color.clear.frame(height: 2).id("chat-bottom")
                    }
                    .padding(16)
                }
                .onChange(of: chat.messages.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 8) {
            contextChip
            HStack(spacing: 10) {
                TextField("Stelle eine Frage zum Unterricht…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .paperCard(cornerRadius: 22)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(canSend ? Theme.accent : Color.secondary.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Frage senden")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.sending
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
    private var contextChip: some View {
        HStack(spacing: 6) {
            if model.phase == .recording {
                Label("Kontext: Aktuelle Aufnahme", systemImage: "record.circle")
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
                        Text("Kontext: \(chat.context.label)")
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func title(for lesson: BackendAPI.LessonInfo) -> String {
        lesson.title ?? lesson.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadLessons() async {
        lessons = await (try? api.listLessons().filter { $0.segmentCount > 0 }) ?? []
    }
}

private struct MessageBubble: View {
    let message: ChatStore.Message

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                Text(renderedMarkdown(message.text))
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                if message.role == .assistant {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Antwort kopieren")
                }
            }
            .padding(12)
            .background(
                message.role == .user ? Theme.accent.opacity(0.14) : Theme.card,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}
