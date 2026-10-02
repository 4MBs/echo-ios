import PhotosUI
import SwiftUI
import UIKit

/// Echo's transcript-aware chat, presented with SwiftChat's conversation and
/// composer design. The outer app sidebar remains the source of navigation;
/// conversation history lives one level inside this tab.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var draft = ""
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var pendingAttachments: [ChatStore.Attachment] = []
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var processingAttachmentCount = 0
    @State private var showAddSheet = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showHistory = false
    @State private var pendingPickerAction: PickerAction?
    @State private var editingMessage: ChatStore.Message?
    @State private var localError: String?
    @State private var dictationPrefix = ""
    @State private var voiceInput = ChatVoiceInput()
    @FocusState private var inputFocused: Bool

    private enum PickerAction {
        case camera, photos, files
    }

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
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .background(Color(.systemBackground).ignoresSafeArea())
                .toolbar { chatToolbar }
        }
        .task { await loadLessons() }
        .onAppear { syncContextWithRecording() }
        .onDisappear { voiceInput.stop() }
        .onChange(of: model.phase) { syncContextWithRecording() }
        .onChange(of: chat.selectedConversationID) { syncContextWithRecording() }
        .onChange(of: voiceInput.transcript) { _, transcript in
            guard !transcript.isEmpty else { return }
            draft = dictationPrefix + transcript
        }
        .onChange(of: voiceInput.errorMessage) { _, error in
            if let error { localError = error }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            processPhotos(items)
        }
        .sheet(isPresented: $showHistory) {
            ChatHistorySheet(chat: chat)
        }
        .sheet(item: $editingMessage) { message in
            ChatMessageEditSheet(message: message) { text in
                chat.editAndResend(message.id, text: text, api: api)
            }
        }
        .sheet(isPresented: $showAddSheet, onDismiss: presentPendingPicker) {
            ChatAddSheet(
                canUseCamera: UITestRuntime.isEnabled || UIImagePickerController.isSourceTypeAvailable(.camera),
                onCamera: { choose(.camera) },
                onPhotos: { choose(.photos) },
                onFiles: { choose(.files) }
            )
            .presentationDetents([.height(300)])
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 5,
            matching: .images
        )
        .fullScreenCover(isPresented: $showCamera) {
            ChatCameraPicker { data in
                showCamera = false
                if let data { processImage(data, fileName: "Kamerafoto.jpg") }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: ChatAttachmentProcessor.importTypes,
            allowsMultipleSelection: true,
            onCompletion: processDocuments
        )
        .alert("Anhang nicht verfügbar", isPresented: errorPresented) {
            Button("OK", role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "Unbekannter Fehler")
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Chatverlauf")

            if !chat.messages.isEmpty {
                Button {
                    chat.createConversation(context: defaultContext)
                    draft = ""
                    pendingAttachments = []
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Neue Unterhaltung")

                Menu {
                    Button("Unterhaltung leeren", systemImage: "eraser", role: .destructive) {
                        chat.clear()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Chatoptionen")
            }
        }
    }

    private var defaultContext: ChatStore.Context {
        model.phase == .recording ? .live : .none
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
            ChatEmptyState(context: chat.context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                            ChatMessageRow(
                                message: message,
                                isLastAssistant: message.role == .assistant && index == chat.messages.count - 1,
                                isSending: chat.sending,
                                onEdit: { editingMessage = message },
                                onResend: { chat.resend(message.id, api: api) },
                                onRegenerate: { chat.regenerate(after: message.id, api: api) }
                            )
                        }
                        if chat.sending {
                            ChatThinkingIndicator()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                // A conversation opens where it left off. Without this the view
                // starts at the oldest message, which only shows once the thread
                // is longer than the screen — a large text size is enough.
                .defaultScrollAnchor(.bottom)
                .onChange(of: chat.selectedConversationID) {
                    scrollToBottom(proxy)
                }
                .onChange(of: chat.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: chat.sending) {
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 7) {
            composerStatus

            VStack(spacing: 0) {
                if !pendingAttachments.isEmpty || processingAttachmentCount > 0 {
                    ChatAttachmentPreviewBar(
                        attachments: pendingAttachments,
                        processingCount: processingAttachmentCount,
                        onRemove: { id in pendingAttachments.removeAll { $0.id == id } }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                TextField(
                    chat.messages.isEmpty ? "Was möchtest du wissen?" : "Nachricht",
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1 ... 5)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .focused($inputFocused)
                .accessibilityIdentifier("chat.input")
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 10)
                .frame(minHeight: 62, maxHeight: 142, alignment: .topLeading)

                composerControlLayout {
                    HStack(spacing: 8) {
                        Button {
                            showAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 20))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .foregroundStyle(.secondary)
                        .disabled(chat.sending || processingAttachmentCount > 0)
                        .accessibilityLabel("Zum Chat hinzufügen")
                        .accessibilityIdentifier("chat.add")

                        contextMenu
                    }

                    HStack(spacing: 8) {
                        AIModelMenu()
                            .disabled(chat.sending)

                        ComposerVoiceButton(isRecording: voiceInput.isRecording) {
                            if voiceInput.isRecording {
                                voiceInput.stop()
                            } else {
                                dictationPrefix = draft.isEmpty ? "" : draft + " "
                                Task { await voiceInput.start() }
                            }
                        }
                        .disabled(chat.sending || model.phase == .recording)

                        Button {
                            if chat.sending { chat.cancel() } else { send() }
                        } label: {
                            Image(systemName: chat.sending ? "stop.fill" : "arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .controlSize(.regular)
                        .disabled(!chat.sending && !canSend)
                        .accessibilityLabel(chat.sending ? "Antwort stoppen" : "Nachricht senden")
                        .accessibilityIdentifier("chat.send")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
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

    /// The composer's controls sit on one line until the labels need more room
    /// than the composer has. They then take a second line rather than putting
    /// a ceiling on how large the student may set their text.
    private var composerControlLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    @ViewBuilder
    private var contextMenu: some View {
        if model.phase == .recording {
            Label("Live", systemImage: "record.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 9)
                // Same reason as the lesson capsule: grow, never crop.
                .padding(.vertical, 7)
                .frame(minHeight: 32)
                .background(.red.opacity(0.1), in: Capsule())
                .accessibilityLabel("Kontext: Aktuelle Aufnahme")
        } else {
            Menu {
                Button {
                    chat.context = .none
                } label: {
                    if chat.context == .none {
                        Label("Ohne Kontext", systemImage: "checkmark")
                    } else {
                        Text("Ohne Kontext")
                    }
                }
                if !lessons.isEmpty { Divider() }
                // A term's worth of lessons in one flat menu is a list taller
                // than the screen. Past a handful they are filed by subject,
                // the way Stunden files them.
                if lessons.count > Self.flatLessonLimit {
                    ForEach(lessonsBySubject, id: \.subject) { group in
                        Menu(group.subject) {
                            ForEach(group.lessons) { lesson in
                                lessonContextButton(lesson, title: lesson.displayTitle, detail: lessonDate(lesson))
                            }
                        }
                    }
                } else {
                    ForEach(lessonsNewestFirst) { lesson in
                        lessonContextButton(lesson, title: lesson.compactDisplayTitle, detail: lessonDate(lesson))
                    }
                }
            } label: {
                if case .lesson = chat.context {
                    // The subject rather than the word "Stunde": the capsule
                    // should say which lesson, not that there is one.
                    Label(selectedLessonSubject ?? "Stunde", systemImage: "text.book.closed")
                        .lineLimit(1)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 9)
                        // Padding rather than a fixed height: the capsule keeps
                        // its resting size but grows with the student's text
                        // instead of cropping the word inside it.
                        .padding(.vertical, 7)
                        .frame(minHeight: 32)
                        .background(Theme.accent.opacity(0.1), in: Capsule())
                } else {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
            }
            .accessibilityLabel("Kontext: \(chat.context.label)")
        }
    }

    @ViewBuilder
    private var composerStatus: some View {
        if let error = chat.errorMessage {
            ChatStatusPill(error, systemImage: "exclamationmark.triangle.fill", tint: .red)
        } else if !model.connectivity.isOnline {
            ChatStatusPill("Offline — Senden ist gerade nicht möglich.", systemImage: "wifi.slash")
        } else if processingAttachmentCount > 0 {
            ChatStatusPill("Anhang wird lokal verarbeitet…", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
            && !chat.sending
            && processingAttachmentCount == 0
            && model.connectivity.isOnline
    }

    private func send() {
        guard canSend else { return }
        voiceInput.stop()
        let question = draft
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        chat.send(
            question: question,
            attachments: attachments,
            api: api
        )
    }

    // MARK: - Attachments

    private func choose(_ action: PickerAction) {
        if UITestRuntime.isEnabled {
            pendingPickerAction = nil
            showAddSheet = false
            let attachment: ChatStore.Attachment = switch action {
            case .camera:
                .init(
                    kind: .image,
                    fileName: "Kamerafoto.jpg",
                    mimeType: "image/jpeg",
                    byteCount: 24000,
                    extractedText: "Fotografierte Testnotiz: Ursache führt zur Wirkung."
                )
            case .photos:
                .init(
                    kind: .image,
                    fileName: "Testfoto.jpg",
                    mimeType: "image/jpeg",
                    byteCount: 18000,
                    extractedText: "Deterministischer Text aus der Fotomediathek."
                )
            case .files:
                .init(
                    kind: .document,
                    fileName: "Testdokument.pdf",
                    mimeType: "application/pdf",
                    byteCount: 42000,
                    extractedText: "Deterministischer Dokumentinhalt für den Chat."
                )
            }
            pendingAttachments.append(attachment)
            return
        }
        pendingPickerAction = action
        showAddSheet = false
    }

    private func presentPendingPicker() {
        guard let action = pendingPickerAction else { return }
        pendingPickerAction = nil
        switch action {
        case .camera: showCamera = true
        case .photos: showPhotoPicker = true
        case .files: showFileImporter = true
        }
    }

    private func processPhotos(_ items: [PhotosPickerItem]) {
        selectedPhotoItems = []
        for (index, item) in items.enumerated() {
            processingAttachmentCount += 1
            Task {
                defer { processingAttachmentCount -= 1 }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ChatAttachmentProcessor.ProcessingError.unreadable
                    }
                    let name = items.count == 1 ? "Foto.jpg" : "Foto \(index + 1).jpg"
                    try await pendingAttachments.append(ChatAttachmentProcessor.image(data: data, fileName: name))
                } catch {
                    localError = error.localizedDescription
                }
            }
        }
    }

    private func processImage(_ data: Data, fileName: String) {
        processingAttachmentCount += 1
        Task {
            defer { processingAttachmentCount -= 1 }
            do {
                try await pendingAttachments.append(
                    ChatAttachmentProcessor.image(data: data, fileName: fileName)
                )
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func processDocuments(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls.prefix(5) {
                processingAttachmentCount += 1
                Task {
                    defer { processingAttachmentCount -= 1 }
                    do {
                        try await pendingAttachments.append(ChatAttachmentProcessor.document(url: url))
                    } catch {
                        localError = error.localizedDescription
                    }
                }
            }
        case .failure(let error):
            localError = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )
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

// MARK: - Message presentation

private struct ChatMessageRow: View {
    let message: ChatStore.Message
    let isLastAssistant: Bool
    let isSending: Bool
    let onEdit: () -> Void
    let onResend: () -> Void
    let onRegenerate: () -> Void

    @State private var copied = false
    @State private var showLongMessage = false

    var body: some View {
        if message.role == .user {
            // Attachments sit above the bubble rather than inside it. Inside,
            // a file tile pushed the bubble out to its full width and left the
            // question floating at the far end of an empty grey slab.
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    ChatSentAttachments(attachments: message.attachments)
                }
                VStack(alignment: .trailing, spacing: 5) {
                    if message.text.count >= 1200 {
                        Button { showLongMessage = true } label: {
                            ChatLongMessageCard(text: message.text)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(renderedMarkdown(message.text))
                            .font(.body)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            // Message text keeps its own measured height: the
                            // accessibility audit reads a bubble that is even a
                            // point short of its descenders as clipped text.
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chat.message.text")
                    }
                    if message.usedWebSearch {
                        Label("Websuche", systemImage: "globe")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: 640, alignment: .trailing)
                .contextMenu {
                    Button(action: onResend) { Label("Erneut senden", systemImage: "arrow.clockwise") }
                        .disabled(isSending)
                    Button(action: copy) { Label("Kopieren", systemImage: "doc.on.doc") }
                    Button(action: onEdit) { Label("Bearbeiten", systemImage: "pencil") }
                        .disabled(isSending)
                }
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .sheet(isPresented: $showLongMessage) {
                ChatLongMessageSheet(text: message.text)
                    .presentationDetents([.medium, .large])
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(renderedMarkdown(message.text))
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat.message.text")

                HStack(spacing: 4) {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    // Message actions are the smallest controls in the thread;
                    // keep their touch area at the 44-point minimum.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(copied ? "Kopiert" : "Antwort kopieren")
                    .accessibilityIdentifier("chat.copy")

                    if copied {
                        Text("Kopiert")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .accessibilityIdentifier("chat.copy.confirmation")
                    }

                    if isLastAssistant && !isSending {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Antwort neu erstellen")
                        .accessibilityIdentifier("chat.regenerate")
                    }
                    Spacer()
                }

                if isLastAssistant {
                    Text("KI kann Fehler machen. Prüfe wichtige Informationen.")
                        // Footnote rather than the smallest style: this line is
                        // a caution, and caption2 stops shrinking below Large.
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy() {
        UIPasteboard.general.string = message.text
        withAnimation { copied = true }
        Task {
            // Keep the visible and spoken confirmation perceivable without
            // permanently occupying message-action space.
            try? await Task.sleep(for: .seconds(5))
            withAnimation { copied = false }
        }
    }
}

struct ChatThinkingIndicator: View {
    @State private var activeDot = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(activeDot == index ? 1 : 0.3)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 12)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(360))
                withAnimation(.easeInOut(duration: 0.2)) { activeDot = (activeDot + 1) % 3 }
            }
        }
        .accessibilityLabel("KI denkt nach")
    }
}

struct ChatStatusPill: View {
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
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - Choosing a lesson as context

extension ChatView {
    private static let flatLessonLimit = 8

    private var lessonsNewestFirst: [BackendAPI.LessonInfo] {
        lessons.sortedNewestFirst
    }

    private var lessonsBySubject: [(subject: String, lessons: [BackendAPI.LessonInfo])] {
        let groups = Dictionary(grouping: lessonsNewestFirst) { $0.displaySubject ?? otherSubjectName }
        return groups
            .map { (subject: $0.key, lessons: $0.value) }
            .sorted { lhs, rhs in
                if (lhs.subject == otherSubjectName) != (rhs.subject == otherSubjectName) {
                    return rhs.subject == otherSubjectName
                }
                return lhs.subject.localizedStandardCompare(rhs.subject) == .orderedAscending
            }
    }

    private var selectedLessonSubject: String? {
        guard case .lesson(let id, _) = chat.context else { return nil }
        return lessons.first { $0.id == id }?.displaySubject
    }

    /// One lesson in the context menu: its name, the day it was, and a tick
    /// when it is what the next question will be answered from.
    private func lessonContextButton(
        _ lesson: BackendAPI.LessonInfo,
        title: String,
        detail: String
    ) -> some View {
        Button {
            chat.context = .lesson(id: lesson.id, title: lesson.compactDisplayTitle)
        } label: {
            if case .lesson(let id, _) = chat.context, id == lesson.id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
            Text(detail)
        }
    }

    private func lessonDate(_ lesson: BackendAPI.LessonInfo) -> String {
        lesson.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
