@testable import MossLive
import XCTest

final class ReaderPageEntryTests: XCTestCase {
    private let numbering = BookPageNumbering(offset: -4, pageCount: 320)

    func testSanitizingKeepsOnlyFiveDecimalDigits() {
        XCTAssertEqual(ReaderPageEntry.sanitized("a12-3456"), "12345")
        XCTAssertEqual(ReaderPageEntry.sanitized(""), "")
    }

    func testDestinationUsesTheBooksPrintedPageMapping() {
        XCTAssertEqual(
            ReaderPageEntry.destination(for: "12", numbering: numbering),
            16
        )
    }

    func testInvalidOrOutOfRangeInputHasNoDestination() {
        XCTAssertNil(ReaderPageEntry.destination(for: "", numbering: numbering))
        XCTAssertNil(ReaderPageEntry.destination(for: "0", numbering: numbering))
        XCTAssertNil(ReaderPageEntry.destination(for: "317", numbering: numbering))
        XCTAssertNil(ReaderPageEntry.destination(for: "12a", numbering: numbering))
        XCTAssertNil(ReaderPageEntry.destination(for: "123456", numbering: numbering))
    }

    func testRestoredValueReflectsTheActuallyVisiblePrintedPage() {
        XCTAssertEqual(
            ReaderPageEntry.restoredValue(forPDFPage: 16, numbering: numbering),
            "12"
        )
    }
}

/// The pages the layout transition expects on screen. It moves pictures to
/// these pages' rectangles, so they have to match what PDFKit's book mode
/// actually shows: the cover alone, then two with three, four with five.
final class ReaderSpreadPagesTests: XCTestCase {
    func testSinglePageShowsOnlyThatPage() {
        XCTAssertEqual(BookPDFView.pageIndices(showing: 0, twoUp: false, pageCount: 10), [0])
        XCTAssertEqual(BookPDFView.pageIndices(showing: 7, twoUp: false, pageCount: 10), [7])
    }

    func testCoverStandsAloneInASpread() {
        XCTAssertEqual(BookPDFView.pageIndices(showing: 0, twoUp: true, pageCount: 10), [0])
    }

    func testSpreadsPairPrintedTwoWithThree() {
        // Indices are zero-based: index 1 is printed page 2.
        XCTAssertEqual(BookPDFView.pageIndices(showing: 1, twoUp: true, pageCount: 10), [1, 2])
        XCTAssertEqual(BookPDFView.pageIndices(showing: 2, twoUp: true, pageCount: 10), [1, 2])
        XCTAssertEqual(BookPDFView.pageIndices(showing: 5, twoUp: true, pageCount: 10), [5, 6])
        XCTAssertEqual(BookPDFView.pageIndices(showing: 6, twoUp: true, pageCount: 10), [5, 6])
    }

    func testLastPageWithoutAPartnerStandsAlone() {
        XCTAssertEqual(BookPDFView.pageIndices(showing: 9, twoUp: true, pageCount: 10), [9])
    }
}
