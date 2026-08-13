import XCTest

final class LibraryReaderUITests: EchoUITestCase {
    func testShelfReaderNavigationLayoutPageJumpAndRename() {
        openReader()
        XCTAssertTrue(app.buttons["Nächste Seite"].waitForExistence(timeout: 8))
        shot("reader-double-page")

        tap(app.buttons["Nächste Seite"])
        let pageIndicator = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Seite '"))
            .firstMatch
        XCTAssertTrue(pageIndicator.waitForExistence(timeout: 4))
        shot("reader-next-page")
        tap(app.buttons["Vorherige Seite"])

        tap(app.buttons["Seitendarstellung"])
        tap(app.buttons["Einzelseite"])
        shot("reader-single-page")
        tap(app.buttons["Seitendarstellung"])
        tap(app.buttons["Doppelseite"])
        shot("reader-return-double-page")

        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Seite '")).firstMatch
        tap(indicator)
        let pageField = app.textFields["Seitennummer"]
        XCTAssertTrue(pageField.waitForExistence(timeout: 3))
        replaceText(pageField, with: "5")
        tap(app.buttons["Seite öffnen"])
        shot("reader-page-five")

        tap(app.buttons["Buchoptionen"])
        tap(app.buttons["Buch umbenennen…"])
        let nameField = app.textFields["Buchname"]
        replaceText(nameField, with: "Visueller Testname")
        tap(app.buttons["Sichern"])
        XCTAssertTrue(app.navigationBars["Visueller Testname"].waitForExistence(timeout: 4))
        shot("reader-renamed")
        rotateAndCapture("reader-renamed")
    }

    func testBookAssistantHistoryQuestionCitationAndRegionEntry() {
        openReader()
        tap(app.buttons["Seite fragen"])
        XCTAssertTrue(app.textFields["bookAI.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Was zeigt das Beispiel?"].exists)
        shot("book-ai-existing-conversation")

        tap(app.buttons["Chatverlauf"])
        XCTAssertTrue(app.navigationBars["Chatverlauf"].waitForExistence(timeout: 4))
        shot("book-ai-history")
        tap(app.buttons["Neue Unterhaltung"])
        XCTAssertTrue(app.textFields["bookAI.input"].waitForExistence(timeout: 4))
        let field = app.textFields["bookAI.input"]
        field.tap()
        field.typeText("Was ist die Kernaussage?")
        tap(app.buttons["bookAI.send"])
        XCTAssertTrue(app.staticTexts["KI denkt nach"].waitForExistence(timeout: 3))
        shot("book-ai-loading")
        let answer = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'reproduzierbaren Beispiel'"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 8))
        shot("book-ai-answer")

        if app.buttons.matching(NSPredicate(format: "label CONTAINS 'Quelle'")).firstMatch.exists {
            tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Quelle'")).firstMatch)
            shot("book-ai-citations")
        }
        tap(app.buttons["Bereich markieren"])
        let regionInstruction = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Rahmen'"))
            .firstMatch
        XCTAssertTrue(regionInstruction.waitForExistence(timeout: 3))
        shot("reader-region-selection-mode")
        tap(app.buttons["Abbrechen"])
    }

    func testReaderOfflineStillOpensCachedBook() {
        launch(tab: "bibliothek", scenario: "offline")
        tap(app.buttons["Echo Testbuch"])
        XCTAssertTrue(app.buttons["Nächste Seite"].waitForExistence(timeout: 8))
        shot("reader-offline-cached")
    }

    private func openReader() {
        launch(tab: "bibliothek")
        XCTAssertTrue(app.navigationBars["Bibliothek"].waitForExistence(timeout: 5))
        shot("library-shelf")
        tap(app.buttons["Echo Testbuch"])
    }
}
