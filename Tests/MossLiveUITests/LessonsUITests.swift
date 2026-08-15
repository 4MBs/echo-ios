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

    func testArchivedLessonOffersSubjectChange() {
        launch(tab: "stunden")
        tap(button(containing: "Mathematik"))
        let lesson = button(containing: "Ursache und Wirkung")
        XCTAssertTrue(lesson.waitForExistence(timeout: 5))

        lesson.press(forDuration: 1.2)

        XCTAssertTrue(app.buttons["Fach ändern"].waitForExistence(timeout: 3))
    }

    func testManualRetranscriptionExplainsAMissingSafetyRecording() {
        openLesson()
        tapToolbarAction("Transkriptoptionen")
        tap(app.buttons["Aus 48-kHz-Datei neu transkribieren"])
        let explanation = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'keine 48-kHz-Sicherheitsaufnahme'"))
            .firstMatch
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 5),
            "The lesson does not say why it cannot re-transcribe"
        )
        shot("lesson-retranscription-without-recording")
    }

    func testManualRetranscriptionAsksBeforeUploadingTheSafetyRecording() {
        launch(tab: "stunden", scenario: "safetyRecording")
        tap(button(containing: "Mathematik"))
        tap(button(containing: "Ursache und Wirkung"))
        tapToolbarAction("Transkriptoptionen")
        tap(app.buttons["Aus 48-kHz-Datei neu transkribieren"])

        let question = app.staticTexts["48-kHz-Aufnahme neu transkribieren?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "The upload started without asking")
        shot("lesson-retranscription-confirmation")
        // The same anchored dialog as deleting a lesson: iOS 26 offers only the
        // action itself, so backing out means tapping away from it.
        if app.buttons["Abbrechen"].exists {
            tap(app.buttons["Abbrechen"])
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        }
        XCTAssertFalse(question.exists, "The confirmation stayed open after tapping away")
    }

    func testTranscriptSaveFailureIsReportedToTheStudent() {
        launch(tab: "stunden", scenario: "writeError")
        tap(button(containing: "Mathematik"))
        tap(button(containing: "Ursache und Wirkung"))
        tapToolbarAction("Transkriptoptionen")
        tap(app.buttons["Transkript bearbeiten"])
        XCTAssertTrue(app.navigationBars["Transkript bearbeiten"].waitForExistence(timeout: 5))
        tap(app.buttons["Sichern"])

        XCTAssertTrue(
            app.staticTexts["Transkript konnte nicht gespeichert werden"].waitForExistence(timeout: 8),
            "A refused save left the student without an explanation"
        )
        shot("lesson-transcript-save-error")
        tap(app.buttons["OK"])
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
        if app.buttons["Abbrechen"].exists {
            app.buttons["Abbrechen"].tap()
        } else if app.buttons["Fertig"].exists {
            app.buttons["Fertig"].tap()
        }

        tapToolbarAction("Transkriptoptionen")
        tap(app.buttons["Transkript bearbeiten"])
        tap(app.buttons["Versionen"])
        XCTAssertTrue(app.navigationBars["Versionsverlauf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Ursprüngliches Live-Transkript wiederherstellen"].exists)
        shot("lesson-transcript-versions")
        tap(app.buttons["Fertig"])
        if app.buttons["Abbrechen"].exists { tap(app.buttons["Abbrechen"]) }

        tapToolbarAction("Teilen")
        // UIActivityViewController is exposed by XCTest as a popover-backed
        // ActivityListView on current iOS, even on iPhone. It is not an
        // XCUIElementTypeSheet.
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 4))
        shot("lesson-share-sheet")
        app.swipeDown()
    }
}
