@testable import MossLive
import XCTest

/// The Stunden board heads every row with what the lesson was about, which it
/// has to read out of a summary written as prose. These cover the reading — the
/// place the screen can be wrong without looking wrong.
final class LessonTopicTests: XCTestCase {
    func testFirstSentenceBecomesTheHeadline() {
        let topic = lessonTopic(
            from: "In dieser Stunde ging es um die Ableitung von Polynomfunktionen. "
                + "Danach wurde die Kettenregel geübt."
        )
        XCTAssertEqual(topic?.headline, "In dieser Stunde ging es um die Ableitung von Polynomfunktionen")
        XCTAssertEqual(topic?.detail, "Danach wurde die Kettenregel geübt.")
    }

    /// "z. B." is a full stop, a space and a capital letter — every signal a
    /// naive split looks for, in a phrase German summaries are full of.
    func testASpacedAbbreviationIsNotASentenceEnd() {
        let topic = lessonTopic(
            from: "Wir haben Zellorganellen wie z. B. Mitochondrien besprochen. Danach kam die Atmung."
        )
        XCTAssertEqual(topic?.headline, "Wir haben Zellorganellen wie z. B. Mitochondrien besprochen")
        XCTAssertEqual(topic?.detail, "Danach kam die Atmung.")
    }

    /// "den 1. Weltkrieg" — an ordinal, and the most common way a history
    /// summary would otherwise lose its heading halfway through.
    func testAnOrdinalIsNotASentenceEnd() {
        let topic = lessonTopic(
            from: "Im Geschichtsunterricht ging es um den 1. Weltkrieg und seine Ursachen. Danach Weimar."
        )
        XCTAssertEqual(
            topic?.headline, "Im Geschichtsunterricht ging es um den 1. Weltkrieg und seine Ursachen"
        )
    }

    /// A colon two words in is a label, not the end of a thought.
    func testAMarkTooEarlyToBeAHeadlineIsIgnored() {
        let topic = lessonTopic(from: "Thema: Ableitungen von Polynomen. Es wurde viel geübt.")
        XCTAssertEqual(topic?.headline, "Thema: Ableitungen von Polynomen")
        XCTAssertEqual(topic?.detail, "Es wurde viel geübt.")
    }

    /// The excerpt is 200 characters of a longer summary, so it usually ends
    /// mid-thought with the server's ellipsis. That is not a sentence break.
    func testTheServersEllipsisDoesNotSplit() {
        let text = "Die Stunde behandelte die Grundlagen der Wahrscheinlichkeitsrechnung…"
        let topic = lessonTopic(from: text)
        XCTAssertEqual(topic?.headline, text)
        XCTAssertNil(topic?.detail)
    }

    /// A summary that is one long sentence still has to head its row, so the
    /// opening of it is cut to length rather than set as a paragraph.
    func testALongOpeningSentenceIsShortenedInsteadOfSetWhole() throws {
        let text = "In dieser Doppelstunde wurden die Ursachen der Französischen Revolution "
            + "sowie die Rolle des dritten Standes und der Generalstände ausführlich behandelt "
            + "und anschließend verglichen."
        let topic = try XCTUnwrap(lessonTopic(from: text))
        XCTAssertTrue(topic.headline.hasSuffix("…"), "a cut headline says that it was cut")
        XCTAssertLessThanOrEqual(topic.headline.count, 97)
        XCTAssertNil(topic.detail, "nothing goes under a headline that is already cut short")
    }

    /// A heading does not end in a full stop, even when the whole excerpt is
    /// one finished sentence.
    func testAWholeSentenceLosesItsFullStop() {
        XCTAssertEqual(
            lessonTopic(from: "Heute wurde die Photosynthese im Detail besprochen.")?.headline,
            "Heute wurde die Photosynthese im Detail besprochen"
        )
    }

    /// No summary is a state the row draws differently, so it has to be told
    /// apart from an empty one.
    func testNothingToReadIsNothing() {
        XCTAssertNil(lessonTopic(from: nil))
        XCTAssertNil(lessonTopic(from: "   "))
    }
}

/// The figures the board prints: the length on every row, and the two totals in
/// its header.
final class SubjectFiguresTests: XCTestCase {
    func testDurationsReadAsHoursAndMinutes() {
        XCTAssertEqual(lessonDurationText(5040), "1 Std 24 Min")
        XCTAssertEqual(lessonDurationText(3120), "52 Min")
        XCTAssertEqual(lessonDurationText(7200), "2 Std")
        XCTAssertEqual(lessonDurationText(40), "40 s")
    }

    /// Hours once there is an hour, minutes below it: "0,3 Std" is a figure
    /// nobody reads as twenty minutes.
    func testTheHeaderSwitchesUnitAtOneHour() {
        XCTAssertEqual(hoursLabel(2400).unit, "Min")
        XCTAssertEqual(hoursLabel(2400).value, "40")
        XCTAssertEqual(hoursLabel(3600).unit, "Std")
        // The decimal separator belongs to the device's locale, so the digits
        // are what is asserted here.
        XCTAssertTrue(hoursLabel(513_000).value.hasPrefix("142"), "142.5 hours, to one decimal")
    }

    func testAnEmptySubjectStillPrintsAFigure() {
        XCTAssertEqual(hoursLabel(0).value, "0")
        XCTAssertEqual(hoursLabel(0).unit, "Min")
    }
}

/// The board is one list cut into columns that are read one after another. Cut
/// it wrong and the archive silently loses or repeats a lesson.
final class ColumnSplitTests: XCTestCase {
    func testTwoColumnsSplitTheListInHalfInOrder() {
        XCTAssertEqual(splitIntoColumns(Array(1 ... 10), count: 2), [Array(1 ... 5), Array(6 ... 10)])
    }

    /// An odd count leaves the left column one longer, never the right: the
    /// list is read down the left first.
    func testTheLeftColumnTakesTheRemainder() {
        XCTAssertEqual(splitIntoColumns(Array(1 ... 11), count: 2), [Array(1 ... 6), Array(7 ... 11)])
    }

    func testEveryRowSurvivesTheCut() {
        for count in 0 ... 40 {
            let rows = Array(0 ..< count)
            XCTAssertEqual(splitIntoColumns(rows, count: 2).flatMap { $0 }, rows, "\(count) rows")
        }
    }

    /// One lesson is one card, not a card and an empty one beside it.
    func testASingleRowNeverGrowsASecondColumn() {
        XCTAssertEqual(splitIntoColumns([7], count: 2), [[7]])
        XCTAssertEqual(splitIntoColumns([Int](), count: 2), [])
    }

    func testOneColumnKeepsTheWholeList() {
        XCTAssertEqual(splitIntoColumns(Array(1 ... 5), count: 1), [Array(1 ... 5)])
    }
}
