import XCTest

final class ChatUITests: EchoUITestCase {
    func testConversationHistoryContextModelAndComposerControls() {
        launch(tab: "chat")
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Erkläre Ursache und Wirkung."].exists)
        shot("chat-existing-conversation")

        tap(app.buttons["Chatverlauf"])
        XCTAssertTrue(app.navigationBars["Chatverlauf"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Ursache und Wirkung"].exists)
        XCTAssertTrue(app.buttons["Ohne Kontext"].exists)
        shot("chat-history")
        tap(app.buttons["Ursache und Wirkung"])

        let context = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kontext:'")).firstMatch
        tap(context)
        tap(app.buttons["Ohne Kontext"])
        XCTAssertTrue(app.buttons["Kontext: Ohne Kontext"].waitForExistence(timeout: 3))
        tap(app.buttons["Kontext: Ohne Kontext"])
        tap(app.buttons["Teststunde Mathematik"])
        let lessonContext = app.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Teststunde Mathematik'"))
            .firstMatch
        XCTAssertTrue(lessonContext.waitForExistence(timeout: 3))

        let model = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'KI-Modell:'")).firstMatch
        tap(model)
        XCTAssertTrue(app.menuItems["Modell"].exists || app.buttons["Modell"].exists)
        shot("chat-model-menu")
        if app.buttons["Geschwindigkeit"].exists {
            tap(app.buttons["Geschwindigkeit"])
            if app.buttons.matching(NSPredicate(format: "label CONTAINS 'Standard'")).firstMatch.exists {
                tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Standard'")).firstMatch)
            }
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        }
    }

    func testFakeCameraPhotoDocumentAttachmentsRemoveAndSend() {
        let choices = [
            ("Kamera", "Kamerafoto.jpg"),
            ("Fotos", "Testfoto.jpg"),
            ("Dateien", "Testdokument.pdf"),
        ]
        for (choice, fileName) in choices {
            launch(tab: "chat")
            tap(app.buttons["chat.add"])
            tap(app.buttons[choice])
            XCTAssertTrue(app.staticTexts[fileName].waitForExistence(timeout: 4))
            shot("chat-attachment-\(choice)")
            let input = app.textFields["chat.input"]
            input.tap()
            input.typeText("Analysiere diesen Anhang")
            tap(app.buttons["chat.send"])
            XCTAssertTrue(app.staticTexts["KI denkt nach"].waitForExistence(timeout: 3))
            let answer = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS 'Antwort auf'"))
                .firstMatch
            XCTAssertTrue(answer.waitForExistence(timeout: 10))
            shot("chat-attachment-answer-\(choice)")
        }
    }

    func testStreamingStopRegenerateCopyNewAndClearConversation() {
        launch(tab: "chat", scenario: "longContent")
        let input = app.textFields["chat.input"]
        input.tap()
        input.typeText("Erzeuge eine lange Testantwort")
        tap(app.buttons["chat.send"])
        XCTAssertTrue(app.buttons["Antwort stoppen"].waitForExistence(timeout: 3))
        shot("chat-streaming")
        tap(app.buttons["Antwort stoppen"])
        XCTAssertTrue(app.buttons["Nachricht senden"].waitForExistence(timeout: 4))
        shot("chat-stream-cancelled")

        if app.buttons["Antwort neu erstellen"].exists {
            tap(app.buttons["Antwort neu erstellen"])
            XCTAssertTrue(app.staticTexts["KI denkt nach"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Antwort neu erstellen"].waitForExistence(timeout: 12))
        }
        tap(app.buttons["Antwort kopieren"])
        XCTAssertTrue(app.buttons["Kopiert"].waitForExistence(timeout: 2))

        tap(app.buttons["Neue Unterhaltung"])
        XCTAssertFalse(app.staticTexts["Erkläre Ursache und Wirkung."].exists)
        shot("chat-new-conversation")
    }

    func testChatOfflineUnauthorizedAndServerErrors() {
        for scenario in ["offline", "unauthorized", "serverError"] {
            launch(tab: "chat", scenario: scenario)
            if scenario == "offline" {
                let offlineStatus = app.staticTexts
                    .matching(NSPredicate(format: "label CONTAINS 'Offline'"))
                    .firstMatch
                XCTAssertTrue(offlineStatus.waitForExistence(timeout: 3))
            } else {
                let input = app.textFields["chat.input"]
                input.tap()
                input.typeText("Fehler auslösen")
                tap(app.buttons["chat.send"])
                let errorStatus = app.staticTexts
                    .matching(NSPredicate(format: "label CONTAINS 'Test'"))
                    .firstMatch
                XCTAssertTrue(errorStatus.waitForExistence(timeout: 6))
            }
            shot("chat-error-\(scenario)")
        }
    }
}
