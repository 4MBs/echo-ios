import CoreGraphics
import Foundation

/// Where the text sits on the page the reader is showing.
///
/// Schoolbooks are scans: there is no selectable text in the PDF for the iPad
/// to hit-test, and finding the exercises from the shapes of numbers is a game
/// of whack-a-mole (a line-number ruler down the margin counts just like a task
/// list; a running head numbered "1" is not Aufgabe 1). So the server reads the
/// book once with a layout-aware OCR model and hands back the blocks: where
/// each one is, what it says, and what kind of block it is.
///
/// The app only draws them. Nothing is recognised on the device.
extension BackendAPI {
    /// One tappable block of a page.
    struct PageRegion: Decodable, Identifiable, Hashable, Sendable {
        /// The model's block kind — "ListItem" is one exercise out of a list,
        /// "Text" a paragraph, "Table"/"Caption"/"SectionHeader" what they say.
        let label: String
        /// Fractions of the page, origin top left: x0, y0, x1, y1. The server
        /// does not know how the page is rendered here, so it never sends
        /// pixels.
        let bbox: [Double]
        let text: String

        var id: String { "\(label)-\(bbox)-\(text.prefix(24))" }

        /// Whether this block is one exercise, which is what the student
        /// usually means to tap.
        var isExercise: Bool { label == "ListItem" }

        /// The rectangle in a page of the given size, with the origin moved to
        /// the bottom left — PDFKit's convention.
        func rect(in bounds: CGRect) -> CGRect {
            guard bbox.count == 4 else { return .zero }
            let x0 = bounds.minX + bbox[0] * bounds.width
            let x1 = bounds.minX + bbox[2] * bounds.width
            // y0/y1 count down from the top of the page; PDFKit counts up.
            let top = bounds.minY + (1 - bbox[1]) * bounds.height
            let bottom = bounds.minY + (1 - bbox[3]) * bounds.height
            return CGRect(x: x0, y: min(top, bottom), width: x1 - x0, height: abs(top - bottom))
        }
    }

    /// What the server knows about a book: whether it has been read yet, and
    /// the regions of the pages asked for.
    struct PageRegions: Decodable, Sendable {
        /// "ready", "scanning" or "none" — a book nobody has scanned yet is a
        /// different thing from a page with nothing on it.
        let status: String
        /// How far a running scan has got, 0…1.
        let fraction: Double?
        /// Keyed by PDF page number.
        let pages: [String: [PageRegion]]

        var isReady: Bool { status == "ready" }
        var isScanning: Bool { status == "scanning" }

        func regions(onPage page: Int) -> [PageRegion] {
            pages[String(page)] ?? []
        }

        enum CodingKeys: String, CodingKey {
            case status, fraction, pages
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "none"
            fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
            pages = try c.decodeIfPresent([String: [PageRegion]].self, forKey: .pages) ?? [:]
        }
    }

    /// The regions of the PDF pages currently on screen.
    func bookRegions(id: String, pages: [Int]) async throws -> PageRegions {
        let list = pages.map(String.init).joined(separator: ",")
        let data = try await request(
            "/library/\(id)/regions",
            query: [URLQueryItem(name: "pages", value: list)]
        )
        return try JSONDecoder().decode(PageRegions.self, from: data)
    }
}
