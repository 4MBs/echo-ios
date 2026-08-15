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
