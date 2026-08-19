import UIKit
import XCTest

final class LibraryReaderUITests: EchoUITestCase {
    /// The two things the page control got wrong in use: it grew while it was
    /// being typed into, and a tap somewhere else did not always end the entry.
    func testReaderPageEntryKeepsItsSizeAndEndsOnTheFirstTapOutside() {
        openReader()
        XCTAssertTrue(app.buttons["Nächste Seite"].waitForExistence(timeout: 8))

        let pageField = app.textFields["Seitennummer"]
        let back = app.buttons["Vorherige Seite"]
        let forward = app.buttons["Nächste Seite"]
        XCTAssertTrue(
            pageField.waitForExistence(timeout: 3),
            "The mounted page field is unavailable before the first tap"
        )
        // Only the horizontal geometry is compared: a keyboard is allowed to
        // lift the whole bar, but nothing in it may change size or slide
        // sideways just because the field is being typed into.
        let restingField = pageField.frame
        let restingBack = back.frame
        let restingForward = forward.frame

        tap(pageField)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 3),
            "A single tap did not focus the page field"
        )
        shot("reader-page-entry-focused")
        XCTAssertEqual(pageField.frame.width, restingField.width, "The page field grew while it was being edited")
        XCTAssertEqual(back.frame.minX, restingBack.minX, "Editing pushed the previous-page button aside")
        XCTAssertEqual(back.frame.width, restingBack.width, "Editing resized the previous-page button")
        XCTAssertEqual(forward.frame.maxX, restingForward.maxX, "Editing pushed the next-page button aside")
        XCTAssertEqual(forward.frame.width, restingForward.width, "Editing resized the next-page button")

        pageField.typeText("5")
        // Double-page mode anchors the visible 4–5 spread at printed page 4.
        let atRequestedSpread = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '4'"),
            object: pageField
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [atRequestedSpread], timeout: 5),
            .completed,
            "The page jump never arrived at the spread containing printed page 5"
        )

        // Once on the book itself, which PDFKit hears, and once on the sidebar,
        // which it does not. Both are "somewhere else" to the student.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(
            keyboard.waitForNonExistence(timeout: 3),
            "One tap on the book did not end the page entry"
        )
        XCTAssertEqual(pageField.value as? String, "4")
        XCTAssertEqual(pageField.frame.width, restingField.width, "The page field kept its editing size")

        tap(pageField)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        // The navigation bar is not part of the book, so PDFKit never hears
        // this one — and it is exactly where the second tap used to be needed.
        app.navigationBars.firstMatch.tap()
        XCTAssertTrue(
            keyboard.waitForNonExistence(timeout: 3),
            "One tap outside the book did not end the page entry"
        )
    }

    func testShelfReaderNavigationLayoutPageJumpAndRename() {
        openReader()
        XCTAssertTrue(app.buttons["Nächste Seite"].waitForExistence(timeout: 8))
        let pageField = app.textFields["Seitennummer"]
        XCTAssertTrue(
            pageField.waitForExistence(timeout: 3),
            "The mounted page field is unavailable before the first tap"
        )
        shot("reader-double-page")

        let initialPage = pageField.value as? String
        tap(app.buttons["Nächste Seite"])
        let turned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", initialPage ?? "1"),
            object: pageField
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [turned], timeout: 5),
            .completed,
            "The page never turned"
        )
        shot("reader-next-page")
        tap(app.buttons["Vorherige Seite"])

        tap(app.buttons["Seitendarstellung"])
        tap(app.buttons["Einzelseite"])
        shot("reader-single-page")
        tap(app.buttons["Seitendarstellung"])
        tap(app.buttons["Doppelseite"])
        shot("reader-return-double-page")

        tap(pageField)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 3),
            "A single tap did not focus the page field"
        )
        // Typing the number is the whole interaction: there is nothing to
        // confirm, so no control is tapped between the digit and the page.
        replaceText(pageField, with: "5")
        XCTAssertFalse(
            app.buttons["Seite öffnen"].exists,
            "The page jump still asks for the number to be confirmed"
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
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

    /// What the shelf says about a book has to come from the iPad. The books
    /// live on a machine reachable only over the VPN, so away from it the list
    /// request is not refused — it hangs until its timeout. The shelf used to
    /// wait for that before looking at its own files, and so put a download
    /// badge on every book already downloaded; tapping one opened it instantly
    /// from disk, which is how obvious the lie was.
    func testShelfNeverOffersToDownloadBooksAlreadyOnTheIPad() {
        launch(tab: "bibliothek", scenario: "offlineStalled")
        XCTAssertTrue(app.navigationBars["Bibliothek"].waitForExistence(timeout: 5))
        let book = app.buttons["Echo Testbuch"]
        XCTAssertTrue(
            book.waitForExistence(timeout: 10),
            "The shelf did not show the downloaded book while the list request was still unanswered"
        )
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Download benötigt'")).count,
            0,
            "A book already on the iPad was offered as a download"
        )
        shot("library-offline-stalled-shelf")
        tap(book)
        XCTAssertTrue(
            app.buttons["Nächste Seite"].waitForExistence(timeout: 8),
            "The book the shelf claimed was here did not open"
        )
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
