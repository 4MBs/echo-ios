import XCTest

final class LessonsUITests: EchoUITestCase {
    func testFolderSearchSortEmptyFolderAndLessonDetailFlows() {
        launch(tab: "stunden")
        XCTAssertTrue(app.navigationBars["Stunden"].waitForExistence(timeout: 5))
        shot("lessons-folders")

        tap(app.buttons["Sortieren"])
        tap(app.buttons["Zuletzt aufgenommen"])
        shot("lessons-sorted-recent")

        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("Physik")
        tap(button(containing: "Physik"))
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        shot("lessons-empty-subject-alert")
        tap(app.alerts.firstMatch.buttons["OK"])
        search.buttons["Clear text"].tap()

        tap(button(containing: "Mathematik"))
        XCTAssertTrue(button(containing: "Ursache und Wirkung").waitForExistence(timeout: 5))
        shot("lessons-subject-board")
        tap(button(containing: "Ursache und Wirkung"))
        let lessonSummary = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Ursache und Wirkung'"))
            .firstMatch
        XCTAssertTrue(lessonSummary.waitForExistence(timeout: 5))
        shot("lesson-detail")
        rotateAndCapture("lesson-detail")
    }

    func testLessonToolbarNotesTranscriptVocabularyAndShare() {
        openLesson()

        tapToolbarAction("Unterrichtsnotizen importieren")
        XCTAssertTrue(app.navigationBars["Unterrichtsnotizen"].waitForExistence(timeout: 4))
        shot("lesson-imported-notes")
        tap(app.buttons["Fertig"])

        tapToolbarAction("Transkriptoptionen")
        tap(app.buttons["Fachwörterbuch"])
        XCTAssertTrue(app.navigationBars["Mathematik"].waitForExistence(timeout: 4))
        shot("lesson-vocabulary")
        if app.textFields.firstMatch.exists {
            typeText("Testbegriff", into: app.textFields.firstMatch)
            tap(app.buttons["Hinzufügen"])
            XCTAssertTrue(app.staticTexts["Testbegriff"].waitForExistence(timeout: 4))
        }
        tap(app.navigationBars.buttons.firstMatch)

        tapToolbarAction("Transkriptoptionen")
        tap(app.buttons["Transkript bearbeiten"])
        let transcriptNavigation = app.navigationBars
            .matching(NSPredicate(format: "identifier CONTAINS 'Transkript'"))
            .firstMatch
        let transcriptText = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Transkript'"))
            .firstMatch
        XCTAssertTrue(transcriptNavigation.waitForExistence(timeout: 4) || transcriptText.exists)
        shot("lesson-transcript-editor")
        if app.buttons["Abbrechen"].exists { app.buttons["Abbrechen"].tap() }
        else if app.buttons["Fertig"].exists { app.buttons["Fertig"].tap() }

        tapToolbarAction("Teilen")
        // UIActivityViewController is exposed by XCTest as a popover-backed
        // ActivityListView on current iOS, even on iPhone. It is not an
        // XCUIElementTypeSheet.
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 4))
        shot("lesson-share-sheet")
        app.swipeDown()
    }

    private func openLesson() {
        launch(tab: "stunden")
        tap(button(containing: "Mathematik"))
        tap(button(containing: "Ursache und Wirkung"))
        let directAction = app.buttons["Transkriptoptionen"]
        let overflow = app.buttons["More"]
        XCTAssertTrue(
            directAction.waitForExistence(timeout: 4) || overflow.waitForExistence(timeout: 6),
            "Lesson toolbar actions are unavailable"
        )
    }

    private func tapToolbarAction(_ label: String) {
        let action = app.buttons[label]
        if action.exists {
            tap(action)
            return
        }

        tap(app.buttons["More"])
        tap(app.buttons[label])
    }
}
