import UIKit
import XCTest

final class LibraryReaderUITests: EchoUITestCase {
    func testShelfReaderNavigationLayoutPageJumpAndRename() {
        openReader()
        XCTAssertTrue(app.buttons["Nächste Seite"].waitForExistence(timeout: 8))
        shot("reader-double-page")

        tap(app.buttons["Nächste Seite"])
        let turned = app.buttons
            .matching(NSPredicate(format: "NOT (label BEGINSWITH 'Seite 1 ')"))
            .matching(NSPredicate(format: "label MATCHES 'Seite [0-9]+.*'"))
            .firstMatch
        XCTAssertTrue(turned.waitForExistence(timeout: 5), "The page never turned")
        shot("reader-next-page")
        tap(app.buttons["Vorherige Seite"])

        tap(app.buttons["Seitendarstellung"])
        tap(app.buttons["Einzelseite"])
        shot("reader-single-page")
        tap(app.buttons["Seitendarstellung"])
        tap(app.buttons["Doppelseite"])
        shot("reader-return-double-page")

        let indicator = app.buttons
            .matching(NSPredicate(format: "label MATCHES 'Seite [0-9]+.*'"))
            .firstMatch
        tap(indicator)
        let pageField = app.textFields["Seitennummer"]
        XCTAssertTrue(pageField.waitForExistence(timeout: 3))
        // Typing the number is the whole interaction: there is nothing to
        // confirm, so no control is tapped between the digit and the page.
        replaceText(pageField, with: "5")
        XCTAssertFalse(
            app.buttons["Seite öffnen"].exists,
            "The page jump still asks for the number to be confirmed"
        )
        tap(app.buttons["Fertig"].firstMatch)
        // Wait for the jump to land before keeping the picture: a screenshot
        // taken mid-transition shows two half-drawn pages and proves nothing.
        let atFive = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Seite 5 ' OR label BEGINSWITH 'Seite 4 '"))
            .firstMatch
        XCTAssertTrue(atFive.waitForExistence(timeout: 5), "The page jump never arrived")
        shot("reader-page-five")

        tap(app.buttons["Buchoptionen"])
        tap(app.buttons["Buch umbenennen…"])
        let nameField = app.textFields["Buchname"]
        replaceText(nameField, with: "Visueller Testname")
        tap(app.buttons["Sichern"])
        XCTAssertTrue(app.navigationBars["Visueller Testname"].waitForExistence(timeout: 4))
        shot("reader-renamed")

        // Teaching the book its printed numbering, and taking it back.
        tap(app.buttons["Seitendarstellung"])
        tap(app.buttons["Seitenzahlen anpassen…"])
        let printedNumber = app.textFields["Gedruckte Seitenzahl"]
        XCTAssertTrue(printedNumber.waitForExistence(timeout: 4))
        typeText("10", into: printedNumber)
        shot("reader-numbering-editor")
        let renumbered = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Seite 10 '"))
            .firstMatch
        XCTAssertTrue(renumbered.waitForExistence(timeout: 5), "The printed page number was not applied")
        tap(app.buttons["Zurücksetzen"])
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()

        tap(app.buttons["Buchoptionen"])
        tap(app.buttons["Originalnamen wiederherstellen"])
        XCTAssertTrue(
            app.navigationBars["Echo Testbuch"].waitForExistence(timeout: 4),
            "The book kept its custom name after restoring the original"
        )
        shot("reader-original-name-restored")
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
        typeText("Was ist die Kernaussage?", into: field)
        tap(app.buttons["bookAI.send"])
        let answer = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'reproduzierbaren Beispiel'"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 8))
        shot("book-ai-answer")

        UIPasteboard.general.items = []
        tap(app.buttons["bookAI.copy"].firstMatch)
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in UIPasteboard.general.hasStrings },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed, "The answer was not copied")
        tap(app.buttons["bookAI.regenerate"])
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "The regenerated answer never arrived")
        shot("book-ai-regenerated")

        if app.buttons.matching(NSPredicate(format: "label CONTAINS 'Quelle'")).firstMatch.exists {
            tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Quelle'")).firstMatch)
            shot("book-ai-citations")
        }
        tap(app.buttons["bookAI.region"])
        shot("reader-region-selection-mode")
    }

    func testReaderOfflineStillOpensCachedBook() {
        launch(tab: "bibliothek", scenario: "offline")
        tap(app.buttons["Echo Testbuch"])
        XCTAssertTrue(app.buttons["Nächste Seite"].waitForExistence(timeout: 8))
        shot("reader-offline-cached")
    }

    func testBookAssistantDictationKeepsComposerGeometryFixed() {
        openReader()
        tap(app.buttons["Seite fragen"])
        let microphone = app.buttons["Frage diktieren"]
        let send = app.buttons["bookAI.send"]
        let input = app.textFields["bookAI.input"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        let microphoneFrame = microphone.frame
        let sendFrame = send.frame
        let inputFrame = input.frame

        tap(microphone)
        let stop = app.buttons["Diktat beenden"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        XCTAssertEqual(stop.frame, microphoneFrame)
        XCTAssertEqual(send.frame, sendFrame)
        XCTAssertEqual(input.frame, inputFrame)
        shot("book-ai-dictation-stable-composer")

        tap(stop)
        XCTAssertTrue(app.buttons["Frage diktieren"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Frage diktieren"].frame, microphoneFrame)
        XCTAssertEqual(send.frame, sendFrame)
        XCTAssertEqual(input.frame, inputFrame)
    }

    func testReaderSwipePinchAndRegionDragGestures() {
        openReader()
        XCTAssertTrue(app.buttons["Nächste Seite"].waitForExistence(timeout: 8))
        let window = app.windows.firstMatch
        window.swipeLeft()
        shot("reader-swipe-left")
        window.swipeRight()
        window.pinch(withScale: 1.6, velocity: 2)
        shot("reader-pinch-zoom-in")
        window.pinch(withScale: 0.62, velocity: -2)
        shot("reader-pinch-zoom-out")

        tap(app.buttons["Seite fragen"])
        // The control keeps one stable identifier while its label changes with
        // the selection state, so the same element can be followed throughout.
        let regionButton = app.buttons["bookAI.region"]
        tap(regionButton)
        // The instructions live on the reader, which stays visible on both form
        // factors — the assistant itself steps aside on compact widths.
        XCTAssertTrue(
            app.staticTexts["Ziehe einen Rahmen um den gewünschten Bereich."].waitForExistence(timeout: 5),
            "Region selection did not become active after tapping the control"
        )
        shot("reader-region-selection-active")
        let isPad = window.frame.width > 700
        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: isPad ? 0.38 : 0.25, dy: 0.25)
        )
        let end = window.coordinate(
            withNormalizedOffset: CGVector(dx: isPad ? 0.58 : 0.68, dy: 0.42)
        )
        start.press(forDuration: 0.35, thenDragTo: end)
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Bereich ausgewählt'"),
            object: regionButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selected], timeout: 6),
            .completed,
            "The drag on the page did not produce a selected region"
        )
        shot("reader-region-selected")

        // The selection is meant to be adjustable afterwards: the overlay says
        // so to VoiceOver, so its handles have to be reachable and it has to
        // move when dragged.
        let adjustment = app.descendants(matching: .any)["Ausgewählter Buchbereich"]
        XCTAssertTrue(adjustment.waitForExistence(timeout: 4), "The chosen region cannot be adjusted")
        let before = adjustment.frame
        adjustment.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: adjustment.coordinate(withNormalizedOffset: CGVector(dx: 1.1, dy: 1.1))
            )
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && element.frame.origin != before.origin
            },
            object: adjustment
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [moved], timeout: 5),
            .completed,
            "Dragging the chosen region did not move it"
        )
        shot("reader-region-adjusted")
        // Compact widths keep the assistant aside while the region is being
        // adjusted, and come back through the banner.
        if app.buttons["Fertig"].exists {
            tap(app.buttons["Fertig"])
            XCTAssertTrue(
                app.buttons["bookAI.region"].waitForExistence(timeout: 5),
                "The assistant did not come back with the marked region"
            )
        }
        tap(app.buttons["Aufheben"])
    }

    private func openReader() {
        launch(tab: "bibliothek")
        XCTAssertTrue(app.navigationBars["Bibliothek"].waitForExistence(timeout: 5))
        shot("library-shelf")
        tap(app.buttons["Echo Testbuch"])
    }
}
