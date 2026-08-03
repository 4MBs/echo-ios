import CoreGraphics
@testable import MossLive
import XCTest

/// Finding the exercises on a schoolbook page so they can be tapped.
///
/// The pages these are modelled on are the real ones the feature was built
/// against: P.A.U.L.D. Oberstufe, printed page 58 — a literary excerpt with a
/// line-number ruler down the margin, and eight numbered tasks under it, every
/// task number set in its own little box. Text recognition reports those boxes
/// as lines of their own, and the ruler as a column of bare numbers that looks
/// exactly like a task list; both are what this grouping has to survive.
final class BookTaskLayoutTests: XCTestCase {
    /// A4-ish, in points, the way PDFKit reports a page.
    private let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// Normalised box for a line of text, given in the reading direction most
    /// people think in: `top` counted down from the top of the page.
    private func line(
        _ text: String,
        top: Double,
        left: Double = 0.10,
        width: Double = 0.36,
        height: Double = 0.018
    ) -> RecognisedLine {
        RecognisedLine(
            text: text,
            box: CGRect(x: left, y: 1 - top - height, width: width, height: height)
        )
    }

    // MARK: - The page the feature was built against

    /// Page 58: the tasks are numbered in boxes, so each number arrives as its
    /// own line beside the wording, and a "5 / 10 / 15" ruler runs down the
    /// margin of the excerpt above them.
    private var pageFiftyEight: [RecognisedLine] {
        [
            // the excerpt, with its line-number ruler in the margin
            line("Ich habe sie höflich gefragt: „Kommen Sie oft hierher?“", top: 0.20),
            line("5", top: 0.20, left: 0.06, width: 0.015),
            line("Sie hat gelächelt. „Fast jeden Tag, den der liebe Gott werden lässt.“", top: 0.23),
            line("Ich bin mir ein bisschen dumm vorgekommen. Aber Nonne ist ja", top: 0.26),
            line("10", top: 0.26, left: 0.06, width: 0.02),
            line("kein Schimpfwort. Jedenfalls nicht für jemanden, der so alt ist.", top: 0.29),
            line("„Ach!“ Ich wusste nicht, was ich sonst hätte sagen sollen.", top: 0.32),
            line("15", top: 0.32, left: 0.06, width: 0.02),
            // the exercises
            line("1", top: 0.60, left: 0.06, width: 0.015),
            line("Lesen Sie den Romanauszug mit verteilten Rollen. Welchen Eindruck haben Sie von", top: 0.60),
            line("den beiden Protagonisten?", top: 0.625),
            line("2", top: 0.66, left: 0.06, width: 0.015),
            line("Charakterisieren Sie das Gesprächsverhalten der Figuren.", top: 0.66),
            line("3", top: 0.70, left: 0.06, width: 0.015),
            line("Inwieweit trägt dieses Gesprächsverhalten im Sinne Watzlawicks zu einer", top: 0.70),
            line("positiven Gestaltung der Beziehungsebene bei?", top: 0.725),
        ]
    }

    func testTheNumberedExercisesAreFound() {
        let tasks = BookTaskLayout.tasks(from: pageFiftyEight, pdfPage: 62, pageBounds: pageBounds)
        XCTAssertEqual(tasks.map(\.number), [1, 2, 3])
        XCTAssertEqual(tasks.map(\.pdfPage), [62, 62, 62])
        XCTAssertEqual(tasks[0].label, "Aufgabe 1")
    }

    /// The wording is what disambiguates "Aufgabe 1" when two pages are on
    /// screen, so it has to survive the boxed number and the line break.
    func testATaskCarriesItsWholeWordingWithoutItsNumber() {
        let tasks = BookTaskLayout.tasks(from: pageFiftyEight, pdfPage: 62, pageBounds: pageBounds)
        XCTAssertEqual(
            tasks[0].text,
            "Lesen Sie den Romanauszug mit verteilten Rollen. Welchen Eindruck haben Sie von "
                + "den beiden Protagonisten?"
        )
        XCTAssertFalse(tasks[0].text.hasPrefix("1"), "the number is the label, not the wording")
        XCTAssertEqual(tasks[1].text, "Charakterisieren Sie das Gesprächsverhalten der Figuren.")
    }

    /// The line numbers down the margin of a literary text are bare numbers in
    /// a column with wording to their right — structurally identical to a task
    /// list. What separates them is that they count in fives.
    func testTheLineNumberRulerIsNotMistakenForExercises() {
        let tasks = BookTaskLayout.tasks(from: pageFiftyEight, pdfPage: 62, pageBounds: pageBounds)
        XCTAssertFalse(tasks.contains { $0.number == 5 }, "line number 5 is not Aufgabe 5")
        XCTAssertFalse(tasks.contains { $0.text.contains("höflich gefragt") })
    }

    func testATaskCoversItsWholeBlockOnThePage() {
        let tasks = BookTaskLayout.tasks(from: pageFiftyEight, pdfPage: 62, pageBounds: pageBounds)
        let first = tasks[0].bounds
        // both lines of task 1, and the number box in front of them
        XCTAssertGreaterThan(first.height, pageBounds.height * 0.04)
        XCTAssertLessThan(first.height, pageBounds.height * 0.12, "it must not swallow task 2")
        XCTAssertFalse(first.intersects(tasks[1].bounds.insetBy(dx: 0, dy: 6)))
        // PDFKit counts from the bottom, so a task lower on the page has the
        // smaller y — this is the check that the boxes are not upside down
        XCTAssertLessThan(tasks[1].bounds.midY, tasks[0].bounds.midY)
    }

    /// A tap is matched against these rectangles, so a point inside the task's
    /// text has to land in exactly one of them.
    func testATapInsideATaskLandsInThatTaskAlone() {
        let tasks = BookTaskLayout.tasks(from: pageFiftyEight, pdfPage: 62, pageBounds: pageBounds)
        for task in tasks {
            let hits = tasks.filter { $0.bounds.contains(CGPoint(x: task.bounds.midX, y: task.bounds.midY)) }
            XCTAssertEqual(hits.map(\.number), [task.number], "Aufgabe \(task.number)")
        }
    }

    // MARK: - What must not become a task

    func testNumbersThatAreNotExerciseNumbersAreIgnored() {
        let lines = [
            line("(2010)", top: 0.30),
            line("WES-129040-014", top: 0.34),
            line("129040", top: 0.38),
            line("58 „Kannst du mich verstehen?“ – Im Labyrinth der Kommunikation", top: 0.05),
        ]
        XCTAssertTrue(BookTaskLayout.tasks(from: lines, pdfPage: 62, pageBounds: pageBounds).isEmpty)
    }

    func testALeadingNumberIsOnlyReadWhenItCouldBeATaskNumber() {
        XCTAssertEqual(BookTaskLayout.leadingNumber("7 Halten Sie es für wichtig")?.number, 7)
        XCTAssertEqual(BookTaskLayout.leadingNumber("2) Charakterisieren")?.rest, "Charakterisieren")
        XCTAssertEqual(BookTaskLayout.leadingNumber("12. Erläutern")?.number, 12)
        XCTAssertNil(BookTaskLayout.leadingNumber("2010 war das Jahr"), "a year is not a task")
        XCTAssertNil(BookTaskLayout.leadingNumber("Lesen Sie den Romanauszug"))
        XCTAssertNil(BookTaskLayout.leadingNumber("0 nichts"))
    }

    /// A page with a running head numbered 58 and one task numbered 1 must not
    /// read the running head as the start of a list.
    func testARunningHeadDoesNotOpenTheList() {
        let lines = [
            line("58 Erwachsen werden, erwachsen sein?", top: 0.04),
            line("1", top: 0.80, left: 0.06, width: 0.015),
            line("Erläutern Sie, ausgehend von Majas Aussage, die Bedeutung der Szene.", top: 0.80),
        ]
        let tasks = BookTaskLayout.tasks(from: lines, pdfPage: 46, pageBounds: pageBounds)
        XCTAssertEqual(tasks.map(\.number), [1])
        XCTAssertTrue(tasks[0].text.hasPrefix("Erläutern Sie"))
    }

    /// Two columns: the task list runs down the left one while the right one
    /// carries body text. A task must not reach across the gutter.
    func testATaskDoesNotReachIntoTheOtherColumn() {
        let lines = [
            line("1", top: 0.60, left: 0.06, width: 0.015),
            line("Fassen Sie den Text anhand der Zwischenüberschriften zusammen.", top: 0.60),
            line("auf den bewussten Einsatz Ihrer Körpersprache.", top: 0.605, left: 0.54, width: 0.36),
            line("2", top: 0.66, left: 0.06, width: 0.015),
            line("Setzen Sie die Aussagen der Autorinnen zur Körpersprache in Beziehung.", top: 0.66),
        ]
        let tasks = BookTaskLayout.tasks(from: lines, pdfPage: 60, pageBounds: pageBounds)
        XCTAssertEqual(tasks.map(\.number), [1, 2])
        XCTAssertFalse(tasks[0].text.contains("bewussten Einsatz"))
        XCTAssertLessThan(tasks[0].bounds.maxX, pageBounds.width * 0.55)
    }

    func testAPageWithNoExercisesYieldsNothing() {
        let prose = (0 ..< 6).map { line("Er steht im Badezimmer vor dem Spiegel.", top: 0.2 + Double($0) * 0.03) }
        XCTAssertTrue(BookTaskLayout.tasks(from: prose, pdfPage: 63, pageBounds: pageBounds).isEmpty)
        XCTAssertTrue(BookTaskLayout.tasks(from: [], pdfPage: 63, pageBounds: pageBounds).isEmpty)
    }
}

/// What a tapped exercise turns into on the wire. The request contract is
/// unchanged — a question plus the visible PDF pages — so the tap has to
/// express itself as a question.
final class BookPageTaskQuestionTests: XCTestCase {
    private let task = BookPageTask(
        pdfPage: 62,
        number: 1,
        text: "Lesen Sie den Romanauszug mit verteilten Rollen. Welchen Eindruck haben Sie von "
            + "den beiden Protagonisten?",
        bounds: CGRect(x: 40, y: 120, width: 300, height: 60)
    )

    func testTheQuestionNamesTheTaskAndQuotesIt() {
        let question = task.question()
        XCTAssertTrue(question.hasPrefix("Löse Aufgabe 1."))
        XCTAssertTrue(question.contains("Lesen Sie den Romanauszug"))
        XCTAssertTrue(question.contains("den beiden Protagonisten?"))
        // the number alone is ambiguous across a spread, the wording is not
        XCTAssertTrue(question.contains("Aufgabenstellung"))
    }

    /// Typing alongside a picked task adds to it rather than replacing it.
    func testAnythingTypedIsAddedToTheTask() {
        let question = task.question(note: "Bitte auf Deutsch und kurz.")
        XCTAssertTrue(question.hasPrefix("Löse Aufgabe 1."))
        XCTAssertTrue(question.hasSuffix("Bitte auf Deutsch und kurz."))
        XCTAssertEqual(task.question(note: "   "), task.question())
    }

    /// The server refuses a question over its limit, and a badly recognised
    /// page could produce a very long one.
    func testTheWordingIsBoundedAndFlattened() {
        let long = BookPageTask(
            pdfPage: 62,
            number: 2,
            text: String(repeating: "sehr lang ", count: 400),
            bounds: .zero
        )
        XCTAssertLessThan(long.question().count, 2000)
        XCTAssertFalse(BookPageTask.shortened("zwei\nZeilen").contains("\n"))
    }

    func testTasksOnDifferentPagesAreDifferentThings() {
        let other = BookPageTask(pdfPage: 63, number: 1, text: task.text, bounds: task.bounds)
        XCTAssertNotEqual(task.id, other.id)
        XCTAssertNotEqual(task, other)
    }
}
