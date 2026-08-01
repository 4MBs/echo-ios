import Foundation
import PDFKit
import UIKit
import Vision
import ZIPFoundation

struct LocalNoteImportResult: Sendable {
    let pages: [LocalNotePage]
    let warnings: [String]
}

enum LocalNoteImporter {
    enum ImportError: LocalizedError {
        case unsupportedFormat
        case emptyDocument
        case unreadableDocument

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                "Unterstützt werden Goodnotes, Notability mit eingebettetem PDF, PDF, JPEG und PNG."
            case .emptyDocument:
                "In diesem Dokument wurde kein Text erkannt."
            case .unreadableDocument:
                "Das Dokument konnte auf diesem iPad nicht gelesen werden."
            }
        }
    }

    private struct OCRResult: Sendable {
        let text: String
        let confidence: Float
    }

    static func extract(from url: URL) async throws -> LocalNoteImportResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let filename = url.lastPathComponent
        let suffix = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        switch suffix {
        case "goodnotes":
            var document = try GoodnotesLocalParser.inspect(data: data, filename: filename)
            // A native Goodnotes export contains only one document thumbnail,
            // not a raster image per page. Use Apple's on-device text model as
            // a conservative second opinion only when there is exactly one
            // exported content page; native typed text always wins.
            if document.pages.count == 1,
               let thumbnail = document.thumbnail,
               let image = UIImage(data: thumbnail),
               let result = await recognize(image),
               !result.text.isEmpty {
                document.pages[0].text = combine(
                    native: document.pages[0].text,
                    localOCR: result,
                    exactTypedLines: document.exactTypedLines
                )
            }
            return result(pages: document.pages)

        case "pdf":
            guard let document = PDFDocument(data: data) else { throw ImportError.unreadableDocument }
            return await result(pages: pdfPages(document, name: stem(filename)))

        case "jpg", "jpeg", "png":
            guard let image = UIImage(data: data) else { throw ImportError.unreadableDocument }
            let recognized = await recognize(image)?.text ?? ""
            return result(pages: [LocalNotePage(title: stem(filename), text: recognized)])

        case "note":
            let archive = try Archive(data: data, accessMode: .read)
            let pdfEntries = archive.filter {
                $0.type == .file && $0.path.lowercased().hasSuffix(".pdf") && $0.uncompressedSize <= 64 * 1024 * 1024
            }
            var pages: [LocalNotePage] = []
            for entry in pdfEntries {
                var pdfData = Data()
                try archive.extract(entry) { chunk in pdfData.append(chunk) }
                guard let document = PDFDocument(data: pdfData) else { continue }
                await pages.append(contentsOf: pdfPages(document, name: stem(filename), startingAt: pages.count))
            }
            return result(pages: pages)

        default:
            throw ImportError.unsupportedFormat
        }
    }

    private static func pdfPages(
        _ document: PDFDocument,
        name: String,
        startingAt: Int = 0
    ) async -> [LocalNotePage] {
        var pages: [LocalNotePage] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // PDFs keep their searchable text exactly. Vision runs locally
            // only when the page is a scan or contains almost no text.
            if text.filter(\.isLetter).count < 8 {
                let bounds = page.bounds(for: .mediaBox)
                let width: CGFloat = 2200
                let height = max(1, width * bounds.height / max(1, bounds.width))
                let image = page.thumbnail(of: CGSize(width: width, height: height), for: .mediaBox)
                if let recognized = await recognize(image) { text = recognized.text }
            }
            pages.append(
                LocalNotePage(
                    title: "\(name) - Seite \(startingAt + index + 1)",
                    text: text
                )
            )
        }
        return pages
    }

    private static func recognize(_ image: UIImage) async -> OCRResult? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.minimumTextHeight = 0.006
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            guard (try? handler.perform([request])) != nil else { return nil }
            let observations = request.results ?? []
            let rows = observations.compactMap { observation -> (CGRect, VNRecognizedText)? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return (observation.boundingBox, candidate)
            }.sorted { lhs, rhs in
                let sameLine = abs(lhs.0.midY - rhs.0.midY) < max(lhs.0.height, rhs.0.height) * 0.55
                if sameLine { return lhs.0.minX < rhs.0.minX }
                // Vision coordinates start at the bottom-left.
                return lhs.0.midY > rhs.0.midY
            }
            let text = rows.map(\.1.string).joined(separator: "\n")
            let confidence = rows.isEmpty
                ? 0
                : rows.reduce(Float(0)) { $0 + $1.1.confidence } / Float(rows.count)
            return OCRResult(text: text, confidence: confidence)
        }.value
    }

    private static func combine(
        native: String,
        localOCR: OCRResult,
        exactTypedLines: [String]
    ) -> String {
        guard localOCR.confidence >= 0.45 else { return native }
        if native.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return localOCR.text }

        let nativeLetters = native.filter(\.isLetter).count
        let ocrLetters = localOCR.text.filter(\.isLetter).count
        // A 499px Goodnotes thumbnail can be too small for reliable OCR. It
        // may replace native handwriting only when it recovered essentially
        // the same amount of content with a healthy model confidence.
        guard ocrLetters >= max(8, Int(Double(nativeLetters) * 0.85)), localOCR.confidence >= 0.55 else {
            return native
        }

        var lines = localOCR.text.split(whereSeparator: \.isNewline).map(String.init)
        for exact in exactTypedLines where !exact.isEmpty {
            if let index = lines.firstIndex(where: { similarity($0, exact) >= 0.62 }) {
                lines[index] = exact
            } else if !lines.contains(where: { normalized($0) == normalized(exact) }) {
                lines.append(exact)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(normalized(lhs))
        let b = Array(normalized(rhs))
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0 ... b.count)
        for (row, character) in a.enumerated() {
            var current = [row + 1]
            for (column, other) in b.enumerated() {
                current.append(
                    min(
                        min(current[column] + 1, previous[column + 1] + 1),
                        previous[column] + (character == other ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func result(pages: [LocalNotePage]) -> LocalNoteImportResult {
        let warnings = Array(Set(pages.compactMap(\.warning))).sorted()
        return LocalNoteImportResult(pages: pages, warnings: warnings)
    }

    private static func stem(_ filename: String) -> String {
        URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    }
}
