import XCTest

/// The paths that remove or rewrite what the student already has: context
/// menus, swipe actions, confirmation dialogs and the alerts behind them. They
/// are separated from the reading flows because a wrong result here loses work.
final class DestructiveFlowsUITests: EchoUITestCase {
    func testChatHistoryRenameAndDeleteThroughContextMenu() {
        launch(tab: "chat")
        openChatHistory()

        let conversation = button(containing: "Ohne Kontext")
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.press(forDuration: 1.2)
        tap(app.buttons["Umbenennen"])

        let title = app.alerts.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        replaceText(title, with: "Umbenannte Unterhaltung")
        shot("chat-history-rename-alert")
        tap(app.alerts.buttons["Sichern"])

        let renamed = button(containing: "Umbenannte Unterhaltung")
        XCTAssertTrue(renamed.waitForExistence(timeout: 4), "The conversation kept its old title")
        shot("chat-history-renamed")

        renamed.press(forDuration: 1.2)
        tap(app.buttons["Löschen"])
        expectToDisappear(renamed, "The deleted conversation is still listed")
        shot("chat-history-deleted")
        tap(app.buttons["Fertig"])
    }

    func testChatHistorySwipeDeletesWithoutTouchingTheOtherConversation() {
        launch(tab: "chat")
        openChatHistory()

        let kept = button(containing: "Ursache und Wirkung")
        let removed = button(containing: "Ohne Kontext")
        XCTAssertTrue(removed.waitForExistence(timeout: 5))
        removed.swipeLeft()
        shot("chat-history-swipe-actions")
        tap(app.buttons["Löschen"])
        expectToDisappear(removed, "The swiped conversation survived its delete action")
        XCTAssertTrue(kept.exists, "Deleting one conversation removed another")
        shot("chat-history-after-swipe-delete")
        tap(app.buttons["Fertig"])
    }

    func testChatMessageContextMenuEditsAndResendsTheQuestion() {
        launch(tab: "chat")
        let question = app.staticTexts["Erkläre Ursache und Wirkung."]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.press(forDuration: 1.2)
        shot("chat-message-context-menu")
        tap(app.buttons["Bearbeiten"])

        XCTAssertTrue(app.navigationBars["Nachricht bearbeiten"].waitForExistence(timeout: 4))
        // A vertical-axis TextField is exposed as a text view once it can grow.
        let editor = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        replaceText(editor, with: "Erkläre den Unterschied.")
        shot("chat-message-edit-sheet")
        tap(app.buttons["Senden"])

        XCTAssertTrue(
            app.staticTexts["Erkläre den Unterschied."].waitForExistence(timeout: 8),
            "The edited question never replaced the original one"
        )
        let answer = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Antwort auf'"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 12), "The edited question was never resent")
        shot("chat-message-edited-answer")
    }

    func testLessonDeleteConfirmationIsCancellableAndThenRemovesTheLesson() {
        launch(tab: "stunden")
        tap(button(containing: "Mathematik"))
        let lesson = button(containing: "Ursache und Wirkung")
        XCTAssertTrue(lesson.waitForExistence(timeout: 6))

        lesson.press(forDuration: 1.2)
        tap(app.buttons["Stunde löschen"])
        XCTAssertTrue(app.staticTexts["Stunde löschen?"].waitForExistence(timeout: 4))
        shot("lesson-delete-confirmation")
        tap(app.buttons["Abbrechen"])
        XCTAssertTrue(lesson.waitForExistence(timeout: 4), "Cancelling the dialog removed the lesson anyway")

        lesson.press(forDuration: 1.2)
        tap(app.buttons["Stunde löschen"])
        tap(app.buttons["Löschen"])
        expectToDisappear(lesson, "The confirmed deletion left the lesson in the list")
        XCTAssertFalse(
            app.staticTexts["Stunde konnte nicht gelöscht werden"].exists,
            "Deleting the lesson reported an error"
        )
        shot("lesson-deleted")
    }

    func testBookAssistantHistoryRenameAndDelete() {
        launch(tab: "bibliothek")
        tap(app.buttons["Echo Testbuch"])
        tap(app.buttons["Seite fragen"])
        tap(app.buttons["Chatverlauf"])
        XCTAssertTrue(app.navigationBars["Chatverlauf"].waitForExistence(timeout: 5))

        let conversation = button(containing: "Zweite Unterhaltung")
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.press(forDuration: 1.2)
        tap(app.buttons["Umbenennen"])
        let title = app.alerts.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        replaceText(title, with: "Buchunterhaltung")
        tap(app.alerts.buttons["Sichern"])

        let renamed = button(containing: "Buchunterhaltung")
        XCTAssertTrue(renamed.waitForExistence(timeout: 4))
        shot("book-ai-history-renamed")

        renamed.swipeLeft()
        tap(app.buttons["Löschen"])
        expectToDisappear(renamed, "The deleted book conversation is still listed")
        shot("book-ai-history-deleted")
        tap(app.buttons["Fertig"])
    }

    private func openChatHistory() {
        tap(app.buttons["Chatverlauf"])
        XCTAssertTrue(app.navigationBars["Chatverlauf"].waitForExistence(timeout: 5))
    }

    private func expectToDisappear(
        _ element: XCUIElement,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 6), .completed, message, file: file, line: line)
    }
}
