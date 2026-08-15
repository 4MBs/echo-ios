import XCTest

final class LearnUITests: EchoUITestCase {
    func testTodayReviewEvaluationMasteryArchiveAndSourceFlow() {
        launch(tab: "lernen")
        XCTAssertTrue(app.navigationBars["Lernen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 heute"].exists)
        XCTAssertTrue(app.staticTexts["ca. 2 Min."].exists)
        XCTAssertTrue(app.staticTexts["Biologie"].exists)
        shot("learn-home")

        tap(app.buttons["Wiederholung starten"])
        let question = app.staticTexts["Warum ist Chlorophyll für die Photosynthese wichtig?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        let answer = app.textViews["learn.answer"]
        tap(answer)
        answer.typeText("Es nimmt Lichtenergie auf.")
        tap(app.buttons["Antwort prüfen"])
        XCTAssertTrue(app.staticTexts["Richtig"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Chlorophyll absorbiert Lichtenergie."].exists)
        shot("learn-review-feedback")

        tap(app.buttons["Quelle öffnen"])
        XCTAssertTrue(app.navigationBars["Erklärung aus der Stunde"].waitForExistence(timeout: 5))
        let transcript = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Chlorophyll absorbiert'")
        ).firstMatch
        XCTAssertTrue(transcript.exists)
        shot("learn-source")
    }

    func testEmptyLearnStateOffersCompletedLessonsForProcessing() {
        launch(tab: "lernen", scenario: "empty")
        XCTAssertTrue(app.staticTexts["Noch keine Lernkonzepte"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stunden auswählen"].exists)
        shot("learn-empty")
        tap(app.buttons["Stunden auswählen"])
        let aiLesson = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Ursache und Wirkung'"))
            .firstMatch
        XCTAssertTrue(aiLesson.waitForExistence(timeout: 5))
        XCTAssertTrue(aiLesson.label.contains("Mathematik"), "The AI title must retain its subject")
    }
}
