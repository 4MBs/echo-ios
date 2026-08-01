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
        mergeGoodnotesText(
            native: native,
            ocrText: localOCR.text,
            ocrConfidence: localOCR.confidence,
            exactTypedLines: exactTypedLines
        )
    }

    static func mergeGoodnotesText(
        native: String,
        ocrText: String,
        ocrConfidence: Float,
        exactTypedLines: [String]
    ) -> String {
        guard ocrConfidence >= 0.45 else { return native }
        if native.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ocrText }

        let nativeLetters = native.filter(\.isLetter).count
        let ocrLetters = ocrText.filter(\.isLetter).count
        // A 499px Goodnotes thumbnail can be too small for reliable OCR. It
        // may replace native handwriting only when it recovered essentially
        // the same amount of content with a healthy model confidence.
        guard ocrLetters >= max(8, Int(Double(nativeLetters) * 0.85)), ocrConfidence >= 0.55 else {
            return native
        }

        let exactLines = exactTypedLines.filter { !$0.isEmpty }
        let exactKeys = Set(exactLines.map(normalized))
        let nativeHandwritingWords = native
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !exactKeys.contains(normalized($0)) }
            .flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .filter { normalized($0).count >= 3 }

        var lines = ocrText.split(whereSeparator: \.isNewline).map(String.init)
        lines = lines.map { line in
            guard !exactLines.contains(where: { similarity(line, $0) >= 0.62 }) else { return line }
            return reconcileHandwriting(line, with: nativeHandwritingWords)
        }

        // Vision may omit a short line at the edge of Goodnotes' 499px
        // thumbnail. Exact typed lines are losslessly available in the native
        // object model, so restore a missing line next to its nearest surviving
        // typed neighbour instead of appending it at the bottom.
        for (exactIndex, exact) in exactLines.enumerated() {
            let occurrence = exactLines.prefix(exactIndex + 1)
                .filter { normalized($0) == normalized(exact) }
                .count
            let matches = matchingLineIndices(in: lines, expected: exact)
            if matches.count >= occurrence {
                let index = matches[occurrence - 1]
                lines[index] = exact
                continue
            }
            let next = exactLines.dropFirst(exactIndex + 1)
                .compactMap { bestLineIndex(in: lines, matching: $0) }
                .first
            let previous = exactLines.prefix(exactIndex).reversed()
                .compactMap { bestLineIndex(in: lines, matching: $0) }
                .first
            let insertion = next ?? previous.map { min(lines.count, $0 + 1) } ?? lines.count
            lines.insert(exact, at: insertion)
        }
        lines = positionHandwritingUsingNativeOrder(
            lines,
            native: native,
            exactLines: exactLines
        )
        return lines.joined(separator: "\n")
    }

    private static func positionHandwritingUsingNativeOrder(
        _ mergedLines: [String],
        native: String,
        exactLines: [String]
    ) -> [String] {
        let nativeLines = native.split(whereSeparator: \.isNewline).map(String.init)
        let exactKeys = Set(exactLines.map(normalized))
        var lines = mergedLines
        var insertedAfter: [String: Int] = [:]

        // Vision occasionally gives one large handwriting box whose midpoint
        // lies above a short typed label. The Goodnotes search data still
        // contains the recognized handwriting tokens in page order, so use
        // those tokens to place the OCR line between its nearest typed anchors.
        let candidates = mergedLines.filter { line in
            !exactLines.contains(where: { similarity(line, $0) >= 0.62 })
        }
        for candidate in candidates {
            let candidateWords = candidate.split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { normalized($0).count >= 3 }
            guard !candidateWords.isEmpty else { continue }

            let evidence = nativeLines.indices.filter { nativeIndex in
                let nativeLine = nativeLines[nativeIndex]
                guard !exactKeys.contains(normalized(nativeLine)) else { return false }
                let nativeWords = nativeLine.split(whereSeparator: \.isWhitespace).map(String.init)
                return candidateWords.contains { word in
                    nativeWords.contains { similarity(word, $0) >= 0.74 }
                }
            }
            guard !evidence.isEmpty, let currentIndex = lines.firstIndex(of: candidate) else { continue }
            let nativeIndex = evidence.sorted()[evidence.count / 2]
            var previousExact: String?
            var previousIndex = nativeIndex
            while previousIndex > 0, previousExact == nil {
                previousIndex -= 1
                let line = nativeLines[previousIndex]
                if exactKeys.contains(normalized(line)) { previousExact = line }
            }
            var nextExact: String?
            var nextIndex = nativeIndex + 1
            while nextIndex < nativeLines.count, nextExact == nil {
                let line = nativeLines[nextIndex]
                if exactKeys.contains(normalized(line)) { nextExact = line }
                nextIndex += 1
            }
            guard previousExact != nil || nextExact != nil else { continue }

            lines.remove(at: currentIndex)
            if let previousExact,
               let anchorIndex = bestLineIndex(in: lines, matching: previousExact) {
                let key = normalized(previousExact)
                let offset = insertedAfter[key, default: 0]
                var insertion = min(lines.count, anchorIndex + 1 + offset)
                if let nextExact,
                   let nextIndex = bestLineIndex(in: lines, matching: nextExact) {
                    insertion = min(insertion, nextIndex)
                }
                lines.insert(candidate, at: insertion)
                insertedAfter[key] = offset + 1
            } else if let nextExact,
                      let nextIndex = bestLineIndex(in: lines, matching: nextExact) {
                lines.insert(candidate, at: nextIndex)
            }
        }
        return lines
    }

    private static func bestLineIndex(in lines: [String], matching expected: String) -> Int? {
        let matches = lines.enumerated().map { ($0.offset, similarity($0.element, expected)) }
        guard let best = matches.max(by: { $0.1 < $1.1 }), best.1 >= 0.62 else { return nil }
        return best.0
    }

    private static func matchingLineIndices(in lines: [String], expected: String) -> [Int] {
        lines.indices.filter { similarity(lines[$0], expected) >= 0.62 }
    }

    private static func reconcileHandwriting(_ line: String, with nativeWords: [String]) -> String {
        line.split(whereSeparator: \.isWhitespace).map { rawWord in
            let word = String(rawWord)
            guard let candidate = nativeWords.max(by: {
                similarity(word, $0) < similarity(word, $1)
            }), similarity(word, candidate) >= 0.74
            else { return word }
            guard normalized(word) != normalized(candidate) else { return word }
            return word.first?.isUppercase == true
                ? candidate.prefix(1).uppercased() + String(candidate.dropFirst())
                : candidate
        }.joined(separator: " ")
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
