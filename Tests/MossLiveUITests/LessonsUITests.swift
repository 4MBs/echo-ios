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
        tap(app.buttons["Physik"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        shot("lessons-empty-subject-alert")
        tap(app.alerts.firstMatch.buttons["OK"])
        search.buttons["Clear text"].tap()

        tap(app.buttons["Mathematik"])
        XCTAssertTrue(app.staticTexts["Teststunde Mathematik"].waitForExistence(timeout: 5))
        shot("lessons-subject-board")
        tap(app.buttons["Teststunde Mathematik"])
        let lessonSummary = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Ursache und Wirkung'"))
            .firstMatch
        XCTAssertTrue(lessonSummary.waitForExistence(timeout: 5))
        shot("lesson-detail")
        rotateAndCapture("lesson-detail")
    }

    func testLessonToolbarNotesTranscriptVocabularyAndShare() {
        openLesson()

        tap(app.buttons["Unterrichtsnotizen importieren"])
        XCTAssertTrue(app.navigationBars["Unterrichtsnotizen"].waitForExistence(timeout: 4))
        shot("lesson-imported-notes")
        tap(app.buttons["Fertig"])

        tap(app.buttons["Transkriptoptionen"])
        tap(app.buttons["Fachwörterbuch"])
        XCTAssertTrue(app.navigationBars["Mathematik"].waitForExistence(timeout: 4))
        shot("lesson-vocabulary")
        if app.textFields.firstMatch.exists {
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText("Testbegriff")
            tap(app.buttons["Hinzufügen"])
            XCTAssertTrue(app.staticTexts["Testbegriff"].waitForExistence(timeout: 4))
        }
        tap(app.navigationBars.buttons.firstMatch)

        tap(app.buttons["Transkriptoptionen"])
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

        tap(app.buttons["Teilen"])
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 4))
        shot("lesson-share-sheet")
        app.swipeDown()
    }

    private func openLesson() {
        launch(tab: "stunden")
        tap(app.buttons["Mathematik"])
        tap(app.buttons["Teststunde Mathematik"])
        XCTAssertTrue(app.buttons["Transkriptoptionen"].waitForExistence(timeout: 5))
    }
}
