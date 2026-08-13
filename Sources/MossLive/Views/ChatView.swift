import PhotosUI
import SwiftUI
import UIKit

/// Echo's transcript-aware chat, presented with SwiftChat's conversation and
/// composer design. The outer app sidebar remains the source of navigation;
/// conversation history lives one level inside this tab.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            Color.clear
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

                HStack(spacing: 8) {
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
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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

    @ViewBuilder
    private var contextMenu: some View {
        if model.phase == .recording {
            Label("Live", systemImage: "record.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(.red.opacity(0.1), in: Capsule())
                .accessibilityLabel("Kontext: Aktuelle Aufnahme")
        } else {
            Menu {
                Button("Ohne Kontext", systemImage: chat.context == .none ? "checkmark" : "circle") {
                    chat.context = .none
                }
                if !lessons.isEmpty { Divider() }
                ForEach(lessons) { lesson in
                    Button(title(for: lesson)) {
                        chat.context = .lesson(id: lesson.id, title: title(for: lesson))
                    }
                }
            } label: {
                if case .lesson = chat.context {
                    Label("Stunde", systemImage: "text.book.closed")
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
            VStack(alignment: .trailing, spacing: 5) {
                if !message.attachments.isEmpty {
                    ChatSentAttachments(attachments: message.attachments)
                }
                if message.text.count >= 1200 {
                    Button { showLongMessage = true } label: {
                        ChatLongMessageCard(text: message.text)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(renderedMarkdown(message.text))
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                }
                if message.usedWebSearch {
                    Label("Websuche", systemImage: "globe")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 640, alignment: .trailing)
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contextMenu {
                Button(action: onResend) { Label("Erneut senden", systemImage: "arrow.clockwise") }
                    .disabled(isSending)
                Button(action: copy) { Label("Kopieren", systemImage: "doc.on.doc") }
                Button(action: onEdit) { Label("Bearbeiten", systemImage: "pencil") }
                    .disabled(isSending)
            }
            .sheet(isPresented: $showLongMessage) {
                ChatLongMessageSheet(text: message.text)
                    .presentationDetents([.medium, .large])
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(renderedMarkdown(message.text))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(copied ? "Kopiert" : "Antwort kopieren")

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
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Antwort neu erstellen")
                    }
                    Spacer()
                }

                if isLastAssistant {
                    Text("KI kann Fehler machen. Prüfe wichtige Informationen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

// MARK: - Attachments

private struct ChatAttachmentPreviewBar: View {
    let attachments: [ChatStore.Attachment]
    let processingCount: Int
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ChatAttachmentChip(attachment: attachment, onRemove: { onRemove(attachment.id) })
                }
                ForEach(0 ..< processingCount, id: \.self) { _ in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Verarbeiten…").font(.caption)
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct ChatAttachmentChip: View {
    let attachment: ChatStore.Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            attachmentPreview
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 210)
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if let data = attachment.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.08)
                Image(systemName: attachment.kind.systemImage)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChatSentAttachments: View {
    let attachments: [ChatStore.Attachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    VStack(alignment: .leading, spacing: 5) {
                        if let data = attachment.thumbnailData, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 150, height: 110)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Image(systemName: attachment.kind.systemImage)
                                .font(.title2)
                        }
                        Text(attachment.fileName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 160, alignment: .leading)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct ChatLongMessageCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text").font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Lange Nachricht").font(.subheadline.weight(.semibold))
                Text("\(text.split(whereSeparator: \.isWhitespace).count) Wörter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(text).font(.caption).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatLongMessageSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("Lange Nachricht")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }
}

// MARK: - Sheets

private struct ChatAddSheet: View {
    let canUseCamera: Bool
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                HStack(spacing: 12) {
                    if canUseCamera { option("Kamera", systemImage: "camera", action: onCamera) }
                    option("Fotos", systemImage: "photo.on.rectangle", action: onPhotos)
                    option("Dateien", systemImage: "doc.badge.plus", action: onFiles)
                }
                Text("Bilderkennung und Dokumenttext werden lokal auf diesem Gerät verarbeitet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Zum Chat hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
        }
    }

    private func option(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(.background, in: Circle())
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.add.\(title.lowercased())")
    }
}

private struct ChatMessageEditSheet: View {
    let message: ChatStore.Message
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(message: ChatStore.Message, onSave: @escaping (String) -> Void) {
        self.message = message
        self.onSave = onSave
        _text = State(initialValue: message.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nachfolgende Antworten werden entfernt und neu erstellt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Nachricht bearbeiten", text: $text, axis: .vertical)
                    .lineLimit(3 ... 10)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                Spacer()
            }
            .padding(20)
            .navigationTitle("Nachricht bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Senden") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ChatHistorySheet: View {
    let chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var renamingConversation: ChatStore.Conversation?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(chat.conversations) { conversation in
                    Button {
                        chat.select(conversation.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !conversation.messages.isEmpty {
                                    Text(conversation.updatedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if conversation.id == chat.selectedConversationID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Löschen", role: .destructive) { chat.delete(conversation.id) }
                        Button("Umbenennen") {
                            renamingConversation = conversation
                            renameText = conversation.title
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button("Umbenennen", systemImage: "pencil") {
                            renamingConversation = conversation
                            renameText = conversation.title
                        }
                        Button("Löschen", systemImage: "trash", role: .destructive) {
                            chat.delete(conversation.id)
                        }
                    }
                }
            }
            .navigationTitle("Chatverlauf")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        chat.createConversation()
                        dismiss()
                    } label: {
                        Label("Neue Unterhaltung", systemImage: "plus")
                    }
                }
            }
            .alert("Unterhaltung umbenennen", isPresented: renamePresented) {
                TextField("Titel", text: $renameText)
                Button("Abbrechen", role: .cancel) { renamingConversation = nil }
                Button("Sichern") {
                    if let conversation = renamingConversation {
                        chat.rename(conversation.id, to: renameText)
                    }
                    renamingConversation = nil
                }
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        )
    }
}
