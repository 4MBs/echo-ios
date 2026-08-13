import Foundation

/// "Seite fragen": a question about the page that is open in the reader.
///
/// The server already has every book (that is where the PDF was downloaded
/// from), so the request carries nothing of the book itself — no file, no page
/// image, no extracted text. The book is named by its library id in the path
/// and the place in it by the PDF page numbers currently on screen. The
/// printed page labels stay on the iPad, where the per-book offset lives.
extension BackendAPI {
    /// A rectangle the student drew on one PDF page. Coordinates are
    /// normalized to that page's crop box, with PDF's bottom-left origin, so
    /// they survive every display size, zoom level and device orientation.
    struct BookPageRegion: Codable, Hashable, Sendable {
        let pdfPage: Int
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        enum CodingKeys: String, CodingKey {
            case x, y, width, height
            case pdfPage = "pdf_page"
        }

        init(pdfPage: Int, x: Double, y: Double, width: Double, height: Double) {
            self.pdfPage = pdfPage
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var json: [String: Any] {
            [
                "pdf_page": pdfPage,
                "x": x,
                "y": y,
                "width": width,
                "height": height,
            ]
        }
    }

    /// One page of the same book the answer rests on. The reader can jump
    /// there, which is why it is a PDF page and not a printed label.
    struct BookCitation: Codable, Identifiable, Hashable, Sendable {
        let pdfPage: Int
        /// Why this page — a few words from the server, often empty.
        let note: String

        var id: Int { pdfPage }

        enum CodingKeys: String, CodingKey {
            case note
            case pdfPage = "pdf_page"
        }

        init(pdfPage: Int, note: String = "") {
            self.pdfPage = pdfPage
            self.note = note
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pdfPage = try c.decode(Int.self, forKey: .pdfPage)
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        }
    }

    struct BookAnswer: Decodable, Sendable {
        let text: String
        let citations: [BookCitation]
        /// The pages the AI actually opened on the server, for the panel's
        /// quiet footnote.
        let pagesRead: [Int]

        enum CodingKeys: String, CodingKey {
            case ok, text, citations
            case pagesRead = "pages_read"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
            let text = try (c.decodeIfPresent(String.self, forKey: .text) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard ok, !text.isEmpty else {
                throw APIError(message: "Der Server hat keine Antwort geliefert.")
            }
            self.text = text
            citations = try c.decodeIfPresent([BookCitation].self, forKey: .citations) ?? []
            pagesRead = try c.decodeIfPresent([Int].self, forKey: .pagesRead) ?? []
        }
    }

    /// Ask about the open book. `pages` are PDF page numbers — one page, or
    /// both pages of a spread.
    func askBook(
        id: String,
        question: String,
        pages: [Int],
        region: BookPageRegion? = nil
    ) async throws -> BookAnswer {
        var body: [String: Any] = ["question": question, "pages": pages]
        if let region { body["region"] = region.json }
        let path = "/library/\(id)/ask"
        let data: Data
        do {
            data = try await request(path, method: "POST", jsonBody: body)
        } catch let error as APIError where region != nil && (error.status == 400 || error.status == 422) {
            // A strict older server can reject the new optional field instead
            // of ignoring it. The question already contains a textual region
            // description, so retrying the established payload still gives it
            // a useful approximation without breaking page questions.
            body["region"] = nil
            data = try await request(path, method: "POST", jsonBody: body)
        }
        return try JSONDecoder().decode(BookAnswer.self, from: data)
    }
}
