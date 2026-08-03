import CoreGraphics
@testable import MossLive
import XCTest

/// Finding the exercises on a schoolbook page so they can be tapped.
///
/// Every fixture here is a real page of P.A.U.L.D. Oberstufe, rebuilt from what
/// the reader shows: printed 30 (a list that starts at 8), 31 (a *numbered
/// running head* above a list that starts at 1), 34 (two columns, 5–7 and
/// 8–10), 38 (prose with a line-number ruler and no exercises at all), 39 (a
/// list that opens at 4) and 58 (a ruler and an exercise list sharing one
/// margin). Between them they cover every way this went wrong on the iPad.
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

    private func tasks(_ lines: [RecognisedLine], page: Int = 62) -> [BookPageTask] {
        BookTaskLayout.tasks(from: lines, pdfPage: page, pageBounds: pageBounds)
    }

    /// A body line the recogniser glued its margin line number onto — the
    /// second of the two shapes a ruler arrives in.
    private func ruled(_ text: String, top: Double) -> RecognisedLine {
        line(text, top: top, left: 0.06, width: 0.38)
    }

    // MARK: - Printed 58: a ruler and an exercise list in the same margin

    /// The tasks are numbered in boxes, so each number arrives as its own line
    /// beside the wording, and a "5 / 10 / 15" ruler runs down the very same
    /// margin above them.
    private var pageFiftyEight: [RecognisedLine] {
        [
            line("Ich habe sie höflich gefragt: „Kommen Sie oft hierher?“", top: 0.20),
            line("5", top: 0.20, left: 0.06, width: 0.015),
            line("Sie hat gelächelt. „Fast jeden Tag, den der liebe Gott werden lässt.“", top: 0.23),
            line("Ich bin mir ein bisschen dumm vorgekommen. Aber Nonne ist ja", top: 0.26),
            line("10", top: 0.26, left: 0.06, width: 0.02),
            line("kein Schimpfwort. Jedenfalls nicht für jemanden, der so alt ist.", top: 0.29),
            line("„Ach!“ Ich wusste nicht, was ich sonst hätte sagen sollen.", top: 0.32),
            line("15", top: 0.32, left: 0.06, width: 0.02),
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

    func testTheExercisesAreFoundUnderARuler() {
        let found = tasks(pageFiftyEight)
        XCTAssertEqual(found.map(\.number), [1, 2, 3])
        XCTAssertFalse(found.contains { $0.text.contains("höflich gefragt") }, "the ruler is not a list")
    }

    /// The wording is what disambiguates "Aufgabe 1" when two pages are on
    /// screen, so it has to survive the boxed number and the line break.
    func testATaskCarriesItsWholeWordingWithoutItsNumber() {
        let found = tasks(pageFiftyEight)
        XCTAssertEqual(
            found[0].text,
            "Lesen Sie den Romanauszug mit verteilten Rollen. Welchen Eindruck haben Sie von "
                + "den beiden Protagonisten?"
        )
        XCTAssertFalse(found[0].text.hasPrefix("1"), "the number is the label, not the wording")
        XCTAssertEqual(found[1].text, "Charakterisieren Sie das Gesprächsverhalten der Figuren.")
    }

    // MARK: - Printed 30: the list starts at 8

    /// Exercise numbering runs across a spread rather than restarting on every
    /// page: this one carries only 8 and 9. Requiring a list to open at a low
    /// number is what left most of the book undetected.
    func testAListThatStartsAtEightIsStillAList() {
        let found = tasks([
            line("30 Erwachsen werden, erwachsen sein?", top: 0.035, left: 0.06, width: 0.30),
            line("Die Gestaltung des Raums in Erzähltexten", top: 0.14),
            line("8", top: 0.72, left: 0.06, width: 0.015),
            line("Probieren Sie verschiedene Möglichkeiten aus, wie man den letzten Satz vorliest.", top: 0.72),
            line("Begründen Sie Ihre Entscheidung und belegen Sie sie am Text.", top: 0.745),
            line("9", top: 0.79, left: 0.06, width: 0.015),
            line("Was Sie noch machen können:", top: 0.79),
        ], page: 34)
        XCTAssertEqual(found.map(\.number), [8, 9])
        XCTAssertFalse(found.contains { $0.text.contains("Erwachsen werden") }, "that is the running head")
    }

    // MARK: - Printed 31: the running head is numbered too

    /// "1 Familienbeziehungen" sits in the top margin and parses exactly like
    /// an exercise. It used to become one — and, being a 1, to take the place
    /// of the page's real Aufgabe 1, which is why 1 went missing while 2 came
    /// through. Nothing in the top or bottom margin is read.
    private var pageThirtyOne: [RecognisedLine] {
        [
            line("1 Familienbeziehungen", top: 0.035, left: 0.60, width: 0.16),
            line("31", top: 0.035, left: 0.86, width: 0.03),
            line("1", top: 0.18, left: 0.58, width: 0.015),
            line("Fassen Sie zusammen, welche Aufgabe der Vater dem Sohn stellt.", top: 0.18, left: 0.62),
            line("2", top: 0.245, left: 0.58, width: 0.015),
            line("Zeigen Sie auf, aus wessen Sicht die Handlung erzählt wird.", top: 0.245, left: 0.62),
            line("3", top: 0.29, left: 0.58, width: 0.015),
            line("Beschreiben Sie in jeweils 1 – 2 Sätzen, welchen Eindruck Sie haben.", top: 0.29, left: 0.62),
            line("4", top: 0.355, left: 0.58, width: 0.015),
            line("Untersuchen Sie das Verhalten von Vater und Sohn genauer:", top: 0.355, left: 0.62),
            line("5", top: 0.44, left: 0.58, width: 0.015),
            line("Zeigen Sie an Beispielen aus dem Text auf, wie der Vater sich verhält.", top: 0.44, left: 0.62),
        ]
    }

    func testTheNumberedRunningHeadIsNotAnExercise() {
        let found = tasks(pageThirtyOne, page: 35)
        XCTAssertEqual(found.map(\.number), [1, 2, 3, 4, 5], "the real Aufgabe 1 must survive")
        XCTAssertFalse(found.contains { $0.text.contains("Familienbeziehungen") })
    }

    /// A tap is matched against these rectangles, so a point inside a task has
    /// to land in exactly one of them.
    func testATapInsideATaskLandsInThatTaskAlone() {
        let found = tasks(pageThirtyOne, page: 35)
        for task in found {
            let point = CGPoint(x: task.bounds.midX, y: task.bounds.midY)
            let hits = found.filter { $0.bounds.contains(point) }
            XCTAssertEqual(hits.map(\.number), [task.number], "Aufgabe \(task.number)")
        }
        // PDFKit counts from the bottom, so a task lower on the page has the
        // smaller y — this is the check that the boxes are not upside down
        XCTAssertLessThan(found[1].bounds.midY, found[0].bounds.midY)
        XCTAssertTrue(found.allSatisfy { $0.bounds.height < pageBounds.height * 0.25 })
    }

    // MARK: - Printed 34: two columns, and the count crosses between them

    func testEachColumnCarriesItsOwnStretchOfTheList() {
        let found = tasks([
            line("34 Erwachsen werden, erwachsen sein?", top: 0.035, left: 0.06, width: 0.30),
            line("5", top: 0.16, left: 0.06, width: 0.015),
            line("Vergleichen Sie das Foto der Familie Hesse mit dem vorliegenden Brief:", top: 0.16),
            line("6", top: 0.30, left: 0.06, width: 0.015),
            line("Charakterisieren Sie den vorliegenden Text als Sachtext.", top: 0.30),
            line("7", top: 0.36, left: 0.06, width: 0.015),
            line("Vergleichen Sie die Gestaltung des Themas in diesem Sachtext.", top: 0.36),
            line("8", top: 0.16, left: 0.50, width: 0.015),
            line("Stellen Sie sich vor, der Sohn des Erzählers trifft Hermann Hesse.", top: 0.16, left: 0.54),
            line("9", top: 0.30, left: 0.50, width: 0.015),
            line("Verfassen Sie in Analogie zu Hesses Text einen Brief an die Mutter.", top: 0.30, left: 0.54),
            line("10", top: 0.36, left: 0.50, width: 0.02),
            line("Informieren Sie sich über den Autor Hermann Hesse und stellen Sie ihn vor.", top: 0.36, left: 0.54),
        ], page: 38)
        XCTAssertEqual(found.map(\.number).sorted(), [5, 6, 7, 8, 9, 10])
    }

    // MARK: - Printed 38: prose, a ruler, and no exercises at all

    /// Recognition reports the margin ruler two different ways in the same
    /// book: sometimes as a bare number of its own, sometimes glued onto the
    /// body line beside it. The second form used to slip past the ruler check
    /// entirely and cover a page of prose in boxes.
    func testAPageOfRuledProseYieldsNothing() {
        let found = tasks([
            line("38 Erwachsen werden, erwachsen sein?", top: 0.035, left: 0.06, width: 0.30),
            line("Unsere Mutter hätte uns warnen können.", top: 0.09),
            ruled("5 Vielleicht würde Aoife dann noch reden.", top: 0.115),
            line("Dara und ich waren beide schon auf Klassenfahrt in Deutschland.", top: 0.14),
            ruled("10 kommen und das Leben hier zu verstehen. Unsere Mutter hat uns", top: 0.19),
            ruled("15 Wir lebten im Heimweh unserer Mutter.", top: 0.24),
            ruled("20 dann, wenn unser Vater wieder betrunken nach Hause kam", top: 0.29),
            ruled("25 konnte wirklich nicht sagen, dass es die Lieblingslieder waren", top: 0.34),
            ruled("30 ein bisschen mehr auf unseren Umzug nach Velgow vorbereitet", top: 0.39),
            ruled("35 Nana Catherine nach Dun Laoghaire gezogen ist, wo es gute", top: 0.44),
            ruled("40 den, denn sie weigerte sich von Anfang an, Deutsch zu reden", top: 0.49),
            ruled("45 gen durch und hört auch dann nicht damit auf, als ich von", top: 0.54),
        ], page: 42)
        XCTAssertTrue(found.isEmpty, "found \(found.map(\.number))")
    }

    // MARK: - Printed 39: the list opens at 4

    func testAListOpeningAtFourIsFound() {
        let found = tasks([
            line("2 Den eigenen Weg finden?", top: 0.035, left: 0.60, width: 0.20),
            line("4", top: 0.09, left: 0.52, width: 0.015),
            line("Beschreiben und erläutern Sie, wie Emma ihre Situation zeigt.", top: 0.09, left: 0.56),
            line("5", top: 0.52, left: 0.52, width: 0.015),
            line("Stellen Sie Ihre Ergebnisse aus Aufgabe 4 in einem Schaubild dar.", top: 0.52, left: 0.56),
            line("6", top: 0.57, left: 0.52, width: 0.015),
            line("Erklären Sie, wie die Leserin durch die Gestaltung beeinflusst wird.", top: 0.57, left: 0.56),
            line("7", top: 0.62, left: 0.52, width: 0.015),
            line("Was Sie noch machen können: Lesen Sie einen anderen Jugendroman.", top: 0.62, left: 0.56),
        ], page: 43)
        XCTAssertEqual(found.map(\.number), [4, 5, 6, 7])
    }

    // MARK: - What must never become a task

    /// One number with nothing counting up beside it is only believed when it
    /// is low enough to open a list.
    func testALoneHighNumberInProseIsNotATask() {
        XCTAssertTrue(tasks([
            line("Der Text stammt aus dem Jahr 1976 und wurde vielfach gedruckt.", top: 0.30),
            line("17 Jahre später erschien eine überarbeitete Fassung des Romans.", top: 0.40),
        ]).isEmpty)
    }

    /// …but a page really can carry a single exercise (printed 42 does).
    func testASingleAufgabeOneIsStillFound() {
        let found = tasks([
            line("42 Erwachsen werden, erwachsen sein?", top: 0.035, left: 0.06, width: 0.30),
            line("1", top: 0.80, left: 0.06, width: 0.015),
            line("Erläutern Sie, ausgehend von Majas Aussage, die Bedeutung der Szene.", top: 0.80),
        ], page: 46)
        XCTAssertEqual(found.map(\.number), [1])
        XCTAssertTrue(found[0].text.hasPrefix("Erläutern Sie"))
    }

    func testNumbersThatAreNotExerciseNumbersAreIgnored() {
        XCTAssertTrue(tasks([
            line("(2010)", top: 0.30),
            line("WES-129040-014", top: 0.34),
            line("129040", top: 0.38),
        ]).isEmpty)
    }

    func testALeadingNumberIsOnlyReadWhenItCouldBeATaskNumber() {
        XCTAssertEqual(BookTaskLayout.leadingNumber("7 Halten Sie es für wichtig")?.number, 7)
        XCTAssertEqual(BookTaskLayout.leadingNumber("2) Charakterisieren")?.rest, "Charakterisieren")
        XCTAssertEqual(BookTaskLayout.leadingNumber("12. Erläutern")?.number, 12)
        XCTAssertNil(BookTaskLayout.leadingNumber("2010 war das Jahr"), "a year is not a task")
        XCTAssertNil(BookTaskLayout.leadingNumber("Lesen Sie den Romanauszug"))
        XCTAssertNil(BookTaskLayout.leadingNumber("0 nichts"))
        // a ruler runs past any exercise number, so spotting one has to see
        // numbers an exercise never reaches
        XCTAssertEqual(BookTaskLayout.leadingInteger("110 und weiter")?.number, 110)
        XCTAssertNil(BookTaskLayout.leadingNumber("110 und weiter"))
        XCTAssertNil(BookTaskLayout.leadingInteger("2010 war das Jahr"))
    }

    func testAPageWithNoExercisesYieldsNothing() {
        let prose = (0 ..< 6).map {
            line("Er steht im Badezimmer vor dem Spiegel.", top: 0.2 + Double($0) * 0.03)
        }
        XCTAssertTrue(tasks(prose).isEmpty)
        XCTAssertTrue(tasks([]).isEmpty)
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
