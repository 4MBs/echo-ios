import CoreGraphics
@testable import MossLive
import XCTest

/// The tappable blocks of a schoolbook page.
///
/// The blocks themselves come from the server, which reads the book once with a
/// layout-aware OCR model — the app no longer works them out from the numbering
/// on the page, which is what used to go wrong (a line-number ruler counts like
/// a task list, a running head numbered "1" is not Aufgabe 1, and a spread's
/// list runs 8, 9 on one page and 1 … 8 on the other). What is left to get
/// right here is the geometry and what a tap turns into.
final class PageRegionGeometryTests: XCTestCase {
    /// A4-ish, in points, the way PDFKit reports a page.
    private let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)

    private func region(_ text: String, _ box: [Double], label: String = "ListItem")
        -> BackendAPI.PageRegion {
        let json = """
        {"label": "\(label)", "bbox": \(box), "text": "\(text)"}
        """
        // decoded rather than constructed, so the wire format is under test too
        return try! JSONDecoder().decode(BackendAPI.PageRegion.self, from: Data(json.utf8))
    }

    /// The server sends fractions of the page counting down from the top;
    /// PDFKit counts up from the bottom. Getting this backwards puts every box
    /// on the wrong half of the page.
    func testTheBoxIsFlippedIntoPdfKitsCoordinates() {
        // a block across the top fifth of the page
        let top = region("1 Fassen Sie zusammen", [0.51, 0.08, 0.92, 0.13]).rect(in: pageBounds)
        XCTAssertEqual(top.minX, 0.51 * 595, accuracy: 0.5)
        XCTAssertEqual(top.width, (0.92 - 0.51) * 595, accuracy: 0.5)
        // top of the page = high y in PDFKit
        XCTAssertEqual(top.maxY, (1 - 0.08) * 842, accuracy: 0.5)
        XCTAssertEqual(top.height, (0.13 - 0.08) * 842, accuracy: 0.5)

        let lower = region("8 Vergleichen Sie", [0.52, 0.76, 0.91, 0.83]).rect(in: pageBounds)
        XCTAssertLessThan(lower.midY, top.midY, "a block further down the page has the smaller y")
        XCTAssertGreaterThan(lower.height, 0)
    }

    func testAMalformedBoxIsHarmless() {
        XCTAssertEqual(region("x", [0.1, 0.2]).rect(in: pageBounds), .zero)
    }

    /// A tap is matched against these rectangles, so a point inside one block
    /// must not land in its neighbour.
    func testTheExercisesOfASpreadDoNotOverlap() {
        let boxes = [
            [0.51, 0.08, 0.92, 0.13], [0.51, 0.13, 0.92, 0.19],
            [0.51, 0.19, 0.92, 0.24], [0.51, 0.24, 0.92, 0.30],
        ]
        let rects = boxes.map { region("task", $0).rect(in: pageBounds) }
        for (index, rect) in rects.enumerated() {
            let point = CGPoint(x: rect.midX, y: rect.midY)
            let hits = rects.enumerated().filter { $0.element.contains(point) }.map(\.offset)
            XCTAssertEqual(hits, [index])
        }
    }

    /// A book nobody has scanned is a different thing from a page with nothing
    /// on it, and the reader has to be able to tell them apart.
    func testAnUnscannedBookIsNotAnEmptyPage() throws {
        let none = try JSONDecoder().decode(
            BackendAPI.PageRegions.self,
            from: Data(#"{"ok": true, "status": "none", "pages": {"35": []}}"#.utf8)
        )
        XCTAssertFalse(none.isReady)
        XCTAssertTrue(none.regions(onPage: 35).isEmpty)

        let scanning = try JSONDecoder().decode(
            BackendAPI.PageRegions.self,
            from: Data(#"{"status": "scanning", "fraction": 0.31, "pages": {}}"#.utf8)
        )
        XCTAssertTrue(scanning.isScanning)
        XCTAssertEqual(scanning.fraction ?? 0, 0.31, accuracy: 0.001)

        let ready = try JSONDecoder().decode(
            BackendAPI.PageRegions.self,
            from: Data("""
            {"status": "ready", "pages": {"35": [
              {"label": "ListItem", "bbox": [0.51, 0.08, 0.92, 0.13], "text": "1 Fassen Sie zusammen"}]}}
            """.utf8)
        )
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.regions(onPage: 35).count, 1)
        XCTAssertTrue(ready.regions(onPage: 35)[0].isExercise)
        XCTAssertTrue(ready.regions(onPage: 36).isEmpty)
    }
}

/// What a tapped block turns into on the wire. The request contract is
/// unchanged — a question plus the visible PDF pages — so the tap has to
/// express itself as a question.
final class BookPageTaskQuestionTests: XCTestCase {
    private func task(_ text: String, label: String = "ListItem") -> BookPageTask {
        BookPageTask(
            pdfPage: 35, index: 0, label: label, text: text,
            bounds: CGRect(x: 40, y: 120, width: 300, height: 60)
        )
    }

    /// Several picked blocks go in one request, numbered, in the order they
    /// were tapped — a student doing 3, 4 and 5 asks once, not three times.
    func testSeveralBlocksBecomeOneNumberedRequest() {
        let three = task("3 Beschreiben Sie in jeweils 1 – 2 Sätzen den Eindruck.")
        let four = task("4 Untersuchen Sie das Verhalten von Vater und Sohn.")
        let five = task("5 Zeigen Sie an Beispielen aus dem Text auf.")
        let question = BookPageTask.question(for: [three, four, five])
        XCTAssertTrue(question.hasPrefix("Löse diese 3 Aufgaben"))
        XCTAssertTrue(question.contains("1. Aufgabe 3:"))
        XCTAssertTrue(question.contains("2. Aufgabe 4:"))
        XCTAssertTrue(question.contains("3. Aufgabe 5:"))
        // the order tapped is the order asked
        XCTAssertLessThan(
            question.range(of: "Aufgabe 3")!.lowerBound,
            question.range(of: "Aufgabe 5")!.lowerBound
        )
    }

    /// A mixed picking — an exercise and a paragraph — is not "solve these".
    func testAMixedSelectionIsWordedForBoth() {
        let exercise = task("1 Fassen Sie zusammen, welche Aufgabe der Vater stellt.")
        let paragraph = task("Der Erzähler kann dem Geschehen neutral gegenüberstehen.", label: "Text")
        let question = BookPageTask.question(for: [exercise, paragraph])
        XCTAssertTrue(question.hasPrefix("Bearbeite diese 2 Stellen"))
        XCTAssertTrue(question.contains("Aufgabe 1:"))
        XCTAssertTrue(question.contains("Diese Stelle:"))
    }

    /// Ten blocks must not push the request past what the server accepts.
    func testManyBlocksStayInsideTheServersLimit() {
        let many = (1 ... 10).map { task("\($0) " + String(repeating: "sehr ausführlich ", count: 60)) }
        let question = BookPageTask.question(for: many, note: "Bitte kurz.")
        XCTAssertLessThan(question.count, 2000)
        XCTAssertTrue(question.contains("10. Aufgabe 10"))
        XCTAssertTrue(question.hasSuffix("Bitte kurz."))
    }

    func testNothingPickedIsJustWhatWasTyped() {
        XCTAssertEqual(BookPageTask.question(for: [], note: "Was ist das?"), "Was ist das?")
    }

    func testAnExerciseIsNamedAndQuoted() {
        let exercise = task("1 Fassen Sie zusammen, welche Aufgabe der Vater dem Sohn stellt.")
        XCTAssertEqual(exercise.number, 1)
        XCTAssertEqual(exercise.labelText, "Aufgabe 1")
        let question = exercise.question()
        XCTAssertTrue(question.hasPrefix("Löse Aufgabe 1."))
        XCTAssertTrue(question.contains("Fassen Sie zusammen"))
        XCTAssertTrue(question.contains("Aufgabenstellung"))
    }

    /// A block that is not an exercise is still worth tapping — it just gets a
    /// different question.
    func testAParagraphIsExplainedRatherThanSolved() {
        let paragraph = task("Der Erzähler kann dem Geschehen neutral gegenüberstehen.", label: "Text")
        XCTAssertFalse(paragraph.isExercise)
        XCTAssertEqual(paragraph.labelText, "Markierter Text")
        let question = paragraph.question()
        XCTAssertTrue(question.hasPrefix("Erkläre diese Stelle"))
        XCTAssertTrue(question.contains("neutral gegenüberstehen"))
        XCTAssertFalse(question.contains("Löse"))
    }

    /// An exercise whose number the model did not put in the text is still a
    /// tappable exercise — nothing here depends on finding a number.
    func testAnUnnumberedExerciseStillWorks() {
        let exercise = task("Vergleichen Sie die beiden Texte miteinander.")
        XCTAssertNil(exercise.number)
        XCTAssertEqual(exercise.labelText, "Aufgabe")
        XCTAssertTrue(exercise.question().hasPrefix("Löse diese Aufgabe."))
    }

    /// Typing alongside a picked block adds to it rather than replacing it.
    func testAnythingTypedIsAddedToTheBlock() {
        let exercise = task("2 Zeigen Sie auf, aus wessen Sicht erzählt wird.")
        let question = exercise.question(note: "Bitte kurz.")
        XCTAssertTrue(question.hasPrefix("Löse Aufgabe 2."))
        XCTAssertTrue(question.hasSuffix("Bitte kurz."))
        XCTAssertEqual(exercise.question(note: "   "), exercise.question())
    }

    /// The server refuses a question over its limit, and a whole column of
    /// prose is a perfectly tappable block.
    func testTheWordingIsBoundedAndFlattened() {
        let long = task(String(repeating: "sehr lang ", count: 400), label: "Text")
        XCTAssertLessThan(long.question().count, 2000)
        XCTAssertFalse(BookPageTask.shortened("zwei\nZeilen").contains("\n"))
    }

    func testBlocksOnDifferentPagesAreDifferentThings() {
        let here = task("1 Fassen Sie zusammen")
        let there = BookPageTask(
            pdfPage: 36, index: 0, label: "ListItem", text: here.text, bounds: here.bounds
        )
        XCTAssertNotEqual(here.id, there.id)
        XCTAssertNotEqual(here, there)
    }

    /// A year is not an exercise number, and neither is a media code.
    func testOnlyASmallLeadingNumberCountsAsTheLabel() {
        XCTAssertNil(task("2010 war das Jahr der Wende.").number)
        XCTAssertNil(task("129040 Vergleichen Sie").number)
        XCTAssertEqual(task("12 Erläutern Sie den Text").number, 12)
    }
}
