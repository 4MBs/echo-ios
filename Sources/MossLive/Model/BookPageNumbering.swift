import Foundation

/// The two page numbers a schoolbook has at the same time: the PDF page the
/// reader is really on, and the number printed on that page.
///
/// They rarely line up — a cover and a few unnumbered pages sit in front, and
/// by how many differs per book, which is why the shift is stored per book.
/// Everything the reader *shows* uses the printed number; everything the
/// server is *asked about* uses the PDF page, because that is the only one
/// both sides can agree on without seeing the same file.
struct BookPageNumbering: Equatable {
    /// Printed page number minus PDF page number.
    var offset: Int
    /// Pages in the PDF; 0 until the document has been parsed.
    var pageCount: Int

    init(offset: Int = 0, pageCount: Int = 0) {
        self.offset = offset
        self.pageCount = pageCount
    }

    /// The number printed on a PDF page. Pages ahead of the book's own page 1 —
    /// cover, title page, whatever else — carry no printed number.
    func printedNumber(_ pdfPage: Int) -> Int? {
        let printed = pdfPage + offset
        return printed >= 1 ? printed : nil
    }

    func printedLabel(_ pdfPage: Int) -> String {
        printedNumber(pdfPage).map(String.init) ?? "—"
    }

    /// What the page indicator says on the right of the slash.
    var printedLast: Int {
        max(pageCount + offset, 0)
    }

    /// The PDF page carrying a printed number, if the book has it.
    func pdfPage(forPrinted printed: Int) -> Int? {
        guard printed >= 1 else { return nil }
        let pdfPage = printed - offset
        return (1 ... max(pageCount, 1)).contains(pdfPage) ? pdfPage : nil
    }

    /// Whether a PDF page exists in this book. A page count of 0 means the
    /// document has not been parsed yet, so nothing can be ruled out.
    func contains(pdfPage: Int) -> Bool {
        pdfPage >= 1 && (pageCount == 0 || pdfPage <= pageCount)
    }

    /// One page or a spread, as the reader would say it: "12", "12–13", "—".
    func printedLabel(forVisible pages: [Int]) -> String {
        let sorted = pages.sorted()
        guard let first = sorted.first else { return "—" }
        guard let last = sorted.last, last != first else { return printedLabel(first) }
        return "\(printedLabel(first))–\(printedLabel(last))"
    }

    /// How a source the AI cited is named in the panel. Printed numbers are
    /// what the student sees on the paper, so they lead; a page in front of the
    /// book's own numbering has none and falls back to the PDF page, which at
    /// least matches the reader's own indicator.
    func citationLabel(pdfPage: Int) -> String {
        printedNumber(pdfPage).map { "Seite \($0)" } ?? "PDF-Seite \(pdfPage)"
    }
}

/// Page-turn availability is based on the whole visible spread, not only its
/// first page. On the final two-page spread `currentPage` is still the left
/// page, so comparing only that value leaves a next button that can never move.
enum BookReaderPaging {
    static func canStepForward(visiblePages: [Int], pageCount: Int) -> Bool {
        guard pageCount > 0 else { return true }
        return (visiblePages.max() ?? 0) < pageCount
    }
}
