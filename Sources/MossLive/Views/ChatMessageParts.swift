import SwiftUI
import UIKit

// The pieces a chat message is built from: the files attached to it, a
// message too long to show inline, and what an empty conversation says.

struct ChatAttachmentPreviewBar: View {
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

struct ChatAttachmentChip: View {
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

struct ChatSentAttachments: View {
    let attachments: [ChatStore.Attachment]

    // The tiles grow with the student's text instead of holding one size and
    // cutting the name in half against the message underneath it.
    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 220
    @ScaledMetric(relativeTo: .caption) private var thumbnailWidth: CGFloat = 150
    @ScaledMetric(relativeTo: .caption) private var thumbnailHeight: CGFloat = 110

    /// Right-aligned like the bubble under them while they fit; a strip that
    /// scrolls once there are more than the column holds.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                tile(attachment)
                    // "Versuchsprotokoll.pdf" spoken as one word is not a
                    // sentence anyone can follow: say what it is instead.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spokenLabel(for: attachment))
            }
        }
    }

    @ViewBuilder
    private func tile(_ attachment: ChatStore.Attachment) -> some View {
        if let data = attachment.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.primary.opacity(0.08), lineWidth: 0.5)
                }
        } else {
            HStack(spacing: 10) {
                Image(systemName: attachment.kind.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName)
                        .font(.subheadline.weight(.medium))
                        // A name cut off at the tile's edge hides the very
                        // part that identifies the file; keep both ends.
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.attachment.name")
                    Text(Self.detail(for: attachment))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: tileWidth, alignment: .leading)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// "PDF · 41 KB" — the type and the size, which is what tells two
    /// attachments with similar names apart.
    private static func detail(for attachment: ChatStore.Attachment) -> String {
        let type = (attachment.fileName as NSString).pathExtension.uppercased()
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
        return type.isEmpty ? size : "\(type) · \(size)"
    }

    private static func spokenLabel(for attachment: ChatStore.Attachment) -> String {
        let name = attachment.fileName as NSString
        let type = name.pathExtension.uppercased()
        let base = name.deletingPathExtension
        return type.isEmpty ? "Anhang: \(base)" : "Anhang: \(base), \(type)"
    }
}

/// What an empty conversation shows: what the chat is for, and what the next
/// question will be answered from. A blank page over a composer said neither.

struct ChatLongMessageCard: View {
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

struct ChatLongMessageSheet: View {
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

struct ChatEmptyState: View {
    let context: ChatStore.Context

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 34

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: glyphSize, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text("Frag etwas zu deinen Stunden")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch context {
        case .live:
            "Die Antworten beziehen sich auf die laufende Aufnahme."
        case .lesson(_, let title):
            "Die Antworten beziehen sich auf „\(title)“."
        case .none:
            "Wähle unten mit dem Buch-Symbol eine Stunde als Grundlage – oder frag einfach los."
        }
    }
}
