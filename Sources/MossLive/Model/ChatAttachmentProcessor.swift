import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

enum ChatAttachmentProcessor {
    enum ProcessingError: LocalizedError {
        case tooLarge
        case unsupported
        case unreadable
        case noText

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                "Anhänge dürfen höchstens 12 MB groß sein."
            case .unsupported:
                "Dieses Dateiformat wird im Chat nicht unterstützt."
            case .unreadable:
                "Der Anhang konnte nicht gelesen werden."
            case .noText:
                "In diesem Dokument wurde kein lesbarer Text gefunden."
            }
        }
    }

    static let importTypes: [UTType] = [
        .pdf, .plainText, .text, .commaSeparatedText, .html, .json,
        UTType(filenameExtension: "md") ?? .plainText,
    ]

    private static let maximumBytes = 12 * 1_024 * 1_024
    private static let maximumExtractedCharacters = 36_000

    static func image(data: Data, fileName: String) async throws -> ChatStore.Attachment {
        guard data.count <= maximumBytes else { throw ProcessingError.tooLarge }
        guard let image = UIImage(data: data) else { throw ProcessingError.unreadable }

        let extracted = await recognize(image) ?? ""
        let upload = image.jpegData(compressionQuality: 0.76) ?? data
        let thumbnail = await thumbnailData(for: image)
        return ChatStore.Attachment(
            kind: .image,
            fileName: fileName,
            mimeType: "image/jpeg",
            byteCount: data.count,
            thumbnailData: thumbnail,
            extractedText: String(extracted.prefix(maximumExtractedCharacters)),
            uploadData: upload
        )
    }

    static func document(url: URL) async throws -> ChatStore.Attachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = values.fileSize ?? 0
        guard size <= maximumBytes else { throw ProcessingError.tooLarge }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let suffix = url.pathExtension.lowercased()
        let text: String
        if suffix == "pdf" {
            guard let document = PDFDocument(data: data) else { throw ProcessingError.unreadable }
            var pages: [String] = []
            for index in 0 ..< document.pageCount {
                guard let page = document.page(at: index) else { continue }
                var pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if pageText.filter(\.isLetter).count < 8 {
                    let bounds = page.bounds(for: .mediaBox)
                    let width: CGFloat = 1_800
                    let image = page.thumbnail(
                        of: CGSize(width: width, height: max(1, width * bounds.height / max(1, bounds.width))),
                        for: .mediaBox
                    )
                    pageText = await recognize(image) ?? ""
                }
                if !pageText.isEmpty { pages.append("Seite \(index + 1)\n\(pageText)") }
                if pages.joined().count >= maximumExtractedCharacters { break }
            }
            text = pages.joined(separator: "\n\n")
        } else if let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) {
            text = decoded
        } else {
            throw ProcessingError.unsupported
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ProcessingError.noText }
        return ChatStore.Attachment(
            kind: .document,
            fileName: url.lastPathComponent,
            mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
            byteCount: data.count,
            extractedText: String(cleaned.prefix(maximumExtractedCharacters))
        )
    }

    private static func recognize(_ image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["de-DE", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            guard (try? handler.perform([request])) != nil else { return nil }
            return request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    @MainActor
    private static func thumbnailData(for image: UIImage) -> Data? {
        let target = CGSize(width: 160, height: 160)
        let scale = max(target.width / image.size.width, target.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(
            x: (target.width - drawSize.width) / 2,
            y: (target.height - drawSize.height) / 2
        )
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }.jpegData(compressionQuality: 0.7)
    }
}
