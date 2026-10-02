import SwiftUI

// MARK: - Sheets

struct ChatAddSheet: View {
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
                // Tinted, so the glyph reads as the control. The disc used to
                // be the card's own colour and disappeared into it.
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
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

struct ChatHistorySheet: View {
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
