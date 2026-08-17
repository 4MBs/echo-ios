@testable import MossLive
import XCTest

/// A schoolbook page has two numbers — the one printed on it and the one the
/// PDF calls it — and "Seite fragen" is where they meet: the reader shows the
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
}

/// `POST /library/{id}/ask` remembers nothing between calls, so a follow-up
/// only means something if the turn before it travels with it.
@MainActor
final class BookAIFollowUpTests: XCTestCase {
    private func turn(question: String, text: String) -> BookAIStore.Turn {
        BookAIStore.Turn(question: question, pages: [16], text: text, citations: [], pagesRead: [16])
    }

    func testAFirstQuestionGoesUpAsTyped() {
        XCTAssertEqual(BookAIStore.grounded("Erkläre diese Seite.", after: nil), "Erkläre diese Seite.")
    }

    /// "Erklär das nochmal einfacher" is unanswerable on its own — what "das"
    /// was has to be in the request.
    func testAFollowUpCarriesThePreviousTurn() {
        let sent = BookAIStore.grounded(
            "Erklär das nochmal einfacher.",
            after: turn(question: "Was ist Zellatmung?", text: "Der Abbau von Glukose.")
        )
        XCTAssertTrue(sent.contains("Was ist Zellatmung?"))
        XCTAssertTrue(sent.contains("Der Abbau von Glukose."))
        XCTAssertTrue(sent.hasSuffix("Erklär das nochmal einfacher."))
    }

    /// The page is the context that matters; a long answer quoted back in full
    /// would crowd it out of the prompt.
    func testALongPreviousAnswerIsCutShort() {
        let long = String(repeating: "a", count: 5000)
        let sent = BookAIStore.grounded("Und weiter?", after: turn(question: "Fasse zusammen.", text: long))
        XCTAssertFalse(sent.contains(long), "the whole answer must not be quoted back")
        XCTAssertTrue(sent.contains("…"), "the quote is marked as cut")
        XCTAssertLessThan(sent.count, 1500)
    }

    func testFreeFormPromptKeepsTheActualRequestAndAddsAGroundedFormatContract() {
        let sent = BookAIPrompts.formatted("Wie funktioniert die Zellatmung?")
        XCTAssertTrue(sent.contains("Wie funktioniert die Zellatmung?"))
        XCTAssertTrue(sent.contains("Erfinde keine Aufgabenstellung"))
        XCTAssertTrue(sent.contains("ausgewählten Buchseiten"))
        XCTAssertTrue(sent.contains("keine Tabellen"))
    }
}

/// Page and rectangle changes alter request grounding without replacing the
/// visible conversation.
@MainActor
final class BookAIContextTests: XCTestCase {
    func testSpreadContextIsStableRegardlessOfPageOrder() {
        XCTAssertEqual(
            BookAIStore.Context(pages: [17, 16, 17]),
            BookAIStore.Context(pages: [16, 17])
        )
    }

    func testDraftAndConversationSurviveAContextChange() {
        let store = BookAIStore(loadPersisted: false)
        let first = BookAIStore.Context(pages: [16])
        let second = BookAIStore.Context(pages: [17])
        let conversationID = store.selectedConversationID

        store.activate(first)
        store.draft = "Frage zu Seite 16"
        store.activate(second)
        XCTAssertEqual(store.draft, "Frage zu Seite 16")
        XCTAssertEqual(store.selectedConversationID, conversationID)
        XCTAssertEqual(store.context, second)
    }

    func testDraftAloneDoesNotExposeConversationCleanup() {
        let store = BookAIStore(loadPersisted: false)
        store.activate(BookAIStore.Context(pages: [16]))

        XCTAssertFalse(store.hasConversation)
        store.draft = "Noch nicht gesendet"
        XCTAssertFalse(store.hasConversation)
        XCTAssertTrue(store.hasContent)
    }

    func testNewConversationCanReturnToThePreviousDraft() {
        let store = BookAIStore(loadPersisted: false)
        let firstID = store.selectedConversationID
        store.draft = "Ungesendete erste Frage"

        store.createConversation()

        XCTAssertEqual(store.conversations.count, 2)
        XCTAssertNotEqual(store.selectedConversationID, firstID)
        XCTAssertEqual(store.draft, "")

        store.select(firstID)
        XCTAssertEqual(store.draft, "Ungesendete erste Frage")
    }

    func testConversationHistorySupportsRenameAndDelete() {
        let store = BookAIStore(loadPersisted: false)
        let firstID = store.selectedConversationID
        store.draft = "Erste Frage"
        store.createConversation()

        store.rename(firstID, to: "Zellatmung")
        XCTAssertEqual(store.conversations.first(where: { $0.id == firstID })?.title, "Zellatmung")

        store.delete(firstID)
        XCTAssertFalse(store.conversations.contains(where: { $0.id == firstID }))
        XCTAssertFalse(store.conversations.isEmpty)
    }

    func testConversationHistoryIsCodableWithBookCitations() throws {
        let turn = BookAIStore.Turn(
            question: "Was zeigt die Abbildung?",
            pages: [16],
            text: "Sie zeigt die Zellatmung.",
            citations: [BackendAPI.BookCitation(pdfPage: 16, note: "Abbildung")],
            pagesRead: [16]
        )
        let conversation = BookAIStore.Conversation(title: "Zellatmung", turns: [turn])

        let encoded = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(BookAIStore.Conversation.self, from: encoded)

        XCTAssertEqual(decoded, conversation)
    }

    func testMarkedRegionIsADifferentContextFromItsWholePage() {
        let region = BackendAPI.BookPageRegion(
            pdfPage: 16,
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4
        )
        XCTAssertNotEqual(
            BookAIStore.Context(pages: [16]),
            BookAIStore.Context(pages: [16], region: region)
        )
    }

    func testRegionUsesNormalizedServerPayloadKeys() throws {
        let region = BackendAPI.BookPageRegion(
            pdfPage: 16,
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4
        )
        let data = try JSONSerialization.data(withJSONObject: region.json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["pdf_page"] as? Int, 16)
        XCTAssertEqual(object["x"] as? Double, 0.1)
        XCTAssertEqual(object["height"] as? Double, 0.4)
    }

    func testRegionAlsoGroundsOlderServersInTheMarkedArea() {
        let region = BackendAPI.BookPageRegion(
            pdfPage: 16,
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4
        )
        let prompt = BookAIStore.scoped("Erkläre das.", to: region)
        XCTAssertTrue(prompt.contains("PDF-Seite 16"))
        XCTAssertTrue(prompt.contains("10 % links / 40 % oben"))
        XCTAssertTrue(prompt.hasSuffix("Erkläre das."))
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

/// Settings and visibility toggles for the Book AI button.
@MainActor
final class BookAIButtonSettingsTests: XCTestCase {
    func testBookAIButtonVisibleByDefaultAndPersistsToggle() {
        let suiteName = "test.mosslive.bookai.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showBookAIButton, "AI button should be visible by default")

        settings.showBookAIButton = false
        XCTAssertFalse(settings.showBookAIButton)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.showBookAIButton, "Toggled state should persist in UserDefaults")

        reloaded.showBookAIButton = true
        XCTAssertTrue(reloaded.showBookAIButton)
    }
}
