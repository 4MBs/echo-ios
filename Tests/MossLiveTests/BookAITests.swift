import Combine
import PDFKit
import SwiftUI
import UIKit
@testable import MossLive
import XCTest

/// A schoolbook page has two numbers — the one printed on it and the one the
/// PDF calls it — and Buch-KI is the place they meet: the reader shows the
/// printed one, the server is only ever told the PDF one, and a citation has
/// to travel back the other way to land on the right page.
final class BookPageNumberingTests: XCTestCase {
    /// A book whose printed page 1 is the fifth page of the PDF.
    private let book = BookPageNumbering(offset: -4, pageCount: 320)

    func testPrintedNumbersFollowTheOffset() {
        XCTAssertEqual(book.printedLabel(5), "1")
        XCTAssertEqual(book.printedLabel(16), "12")
        XCTAssertEqual(book.printedLast, 316)
    }

    /// Cover and title pages sit in front of the book's own numbering and
    /// carry no printed number at all.
    func testPagesBeforePageOneHaveNoPrintedNumber() {
        XCTAssertNil(book.printedNumber(4))
        XCTAssertEqual(book.printedLabel(4), "—")
        XCTAssertEqual(book.printedLabel(1), "—")
    }

    func testJumpingByPrintedNumberStaysInsideTheBook() {
        XCTAssertEqual(book.pdfPage(forPrinted: 12), 16)
        XCTAssertEqual(book.pdfPage(forPrinted: 316), 320)
        XCTAssertNil(book.pdfPage(forPrinted: 317), "past the last page of the PDF")
        XCTAssertNil(book.pdfPage(forPrinted: -3), "no printed number maps in front of the file")
    }

    /// What the panel writes above the prompt field: the spread the question
    /// will be about, in the numbers the student can see on the paper.
    func testASpreadIsNamedAsARange() {
        XCTAssertEqual(book.printedLabel(forVisible: [16, 17]), "12–13")
        XCTAssertEqual(book.printedLabel(forVisible: [17, 16]), "12–13", "order does not matter")
        XCTAssertEqual(book.printedLabel(forVisible: [16]), "12")
        XCTAssertEqual(book.printedLabel(forVisible: []), "—")
    }

    func testCitationsAreNamedWithThePrintedPage() {
        XCTAssertEqual(book.citationLabel(pdfPage: 16), "Seite 12")
        // an unnumbered page still has to say something a tap can be trusted
        // with, so it falls back to the number the reader itself would show
        XCTAssertEqual(book.citationLabel(pdfPage: 2), "PDF-Seite 2")
    }

    func testCitationsOutsideTheBookAreNotTappable() {
        XCTAssertTrue(book.contains(pdfPage: 320))
        XCTAssertFalse(book.contains(pdfPage: 321))
        XCTAssertFalse(book.contains(pdfPage: 0))
        // before the document is parsed nothing is known, so nothing is refused
        XCTAssertTrue(BookPageNumbering(offset: 0, pageCount: 0).contains(pdfPage: 900))
    }

    /// The default book: printed and PDF numbering line up.
    func testAnUnadjustedBookMapsOneToOne() {
        let plain = BookPageNumbering(offset: 0, pageCount: 10)
        XCTAssertEqual(plain.printedLabel(7), "7")
        XCTAssertEqual(plain.pdfPage(forPrinted: 7), 7)
        XCTAssertEqual(plain.citationLabel(pdfPage: 7), "Seite 7")
    }

    func testTheLastVisiblePageControlsForwardNavigation() {
        XCTAssertTrue(BookReaderPaging.canStepForward(visiblePages: [318, 319], pageCount: 320))
        XCTAssertFalse(
            BookReaderPaging.canStepForward(visiblePages: [319, 320], pageCount: 320),
            "the left page of the final spread must not leave a dead next button enabled"
        )
        XCTAssertFalse(BookReaderPaging.canStepForward(visiblePages: [320], pageCount: 320))
        XCTAssertTrue(BookReaderPaging.canStepForward(visiblePages: [1], pageCount: 0))
    }
}

/// Decoding the server's answer: the panel only ever shows citations it can
/// actually jump to, so the PDF page number has to survive intact.
final class BookAnswerDecodingTests: XCTestCase {
    private func answer(_ json: String) throws -> BackendAPI.BookAnswer {
        try JSONDecoder().decode(BackendAPI.BookAnswer.self, from: Data(json.utf8))
    }

    func testAnswerWithCitations() throws {
        let decoded = try answer("""
        {"ok": true, "text": "Die Zellatmung.", "pages_read": [16, 17],
         "citations": [{"pdf_page": 16, "note": "Schaubild"}, {"pdf_page": 84}]}
        """)
        XCTAssertEqual(decoded.text, "Die Zellatmung.")
        XCTAssertEqual(decoded.pagesRead, [16, 17])
        XCTAssertEqual(decoded.citations.map(\.pdfPage), [16, 84])
        XCTAssertEqual(decoded.citations[0].note, "Schaubild")
        XCTAssertEqual(decoded.citations[1].note, "", "a citation without a note is still tappable")
    }

    func testAnAnswerWithoutCitationsDecodes() throws {
        XCTAssertTrue(try answer(#"{"text": "Kurz."}"#).citations.isEmpty)
    }

    /// An empty answer is not an answer — the panel must show an error rather
    /// than a blank card.
    func testEmptyOrRefusedAnswersThrow() {
        XCTAssertThrowsError(try answer(#"{"ok": true, "text": "   "}"#))
        XCTAssertThrowsError(try answer(#"{"ok": false, "error": "unknown book"}"#))
    }
}

final class BookCacheValidationTests: XCTestCase {
    func testAnEmptyOrNonFileCacheEntryIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("book.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        XCTAssertFalse(BackendAPI.isUsableBookFile(file), "a zero-byte interrupted download is not a book")

        try Data("%PDF-1.7".utf8).write(to: file)
        XCTAssertTrue(BackendAPI.isUsableBookFile(file))
        XCTAssertFalse(BackendAPI.isUsableBookFile(root), "a directory cannot masquerade as a cached PDF")
    }
}

/// Exercises the transition that failed on the device: a navigation route is
/// already open, the reader resolves a cached file, and PDFKit replaces the
/// loading view. The route must survive that replacement and the concrete
/// PDFView must use the bounded page-controller layout.
@MainActor
final class BookReaderPresentationTests: XCTestCase {
    func testLoadingAPDFKeepsTheReaderOpen() async throws {
        let id = "reader-presentation-\(UUID().uuidString)"
        let cachedURL = try writeFixture(id: id)
        defer { try? FileManager.default.removeItem(at: cachedURL) }

        let book = BackendAPI.Book(
            id: id,
            title: "Reader regression",
            fileName: "fixture.pdf",
            sizeBytes: Int64(try Data(contentsOf: cachedURL).count)
        )
        let probe = ReaderPathProbe(path: [id])
        let model = AppModel()
        let root = ReaderNavigationHarness(
            probe: probe,
            api: BackendAPI(host: "127.0.0.1", port: 9, token: "test"),
            book: book
        )
        .environment(model)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var pdfView: PDFView?
        for _ in 0 ..< 50 where pdfView == nil {
            host.view.layoutIfNeeded()
            pdfView = firstPDFView(in: host.view)
            if pdfView == nil { try await Task.sleep(for: .milliseconds(20)) }
        }

        let opened = try XCTUnwrap(pdfView, "the loading phase must become a PDFView")
        XCTAssertTrue(opened.isUsingPageViewController)
        XCTAssertEqual(probe.path, [id], "loading the document must not pop the active book")

        // Give PDFKit's initial visible-page notifications time to run; the
        // regression used to occur as soon as those notifications arrived.
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        XCTAssertEqual(probe.path, [id])
        XCTAssertNotNil(firstPDFView(in: host.view))
    }

    private func writeFixture(id: String) throws -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("library-books", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).pdf")
        let bounds = CGRect(x: 0, y: 0, width: 430, height: 590)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            for page in 1 ... 6 {
                renderer.beginPage()
                let context = renderer.cgContext
                context.setStrokeColor(UIColor.black.cgColor)
                context.setLineWidth(1)
                for row in 0 ... 8 {
                    let y = CGFloat(80 + row * 45)
                    context.move(to: CGPoint(x: 35, y: y))
                    context.addLine(to: CGPoint(x: 395, y: y))
                }
                for column in 0 ... 4 {
                    let x = CGFloat(35 + column * 90)
                    context.move(to: CGPoint(x: x, y: 80))
                    context.addLine(to: CGPoint(x: x, y: 440))
                }
                context.strokePath()
                NSString(string: "Synthetic table — page \(page)").draw(
                    at: CGPoint(x: 35, y: 35),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
                )
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func firstPDFView(in view: UIView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let found = firstPDFView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private final class ReaderPathProbe: ObservableObject {
    @Published var path: [String]

    init(path: [String]) {
        self.path = path
    }
}

@MainActor
private struct ReaderNavigationHarness: View {
    @ObservedObject var probe: ReaderPathProbe
    let api: BackendAPI
    let book: BackendAPI.Book

    var body: some View {
        NavigationStack(path: $probe.path) {
            Color.clear
                .navigationDestination(for: String.self) { _ in
                    BookReaderView(api: api, book: book)
                }
        }
    }
}
