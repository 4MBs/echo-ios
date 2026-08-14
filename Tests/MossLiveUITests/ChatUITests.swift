import UIKit
import XCTest

final class ChatUITests: EchoUITestCase {
    func testConversationHistoryContextModelAndComposerControls() {
        launch(tab: "chat")
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Erkläre Ursache und Wirkung."].exists)
        shot("chat-existing-conversation")

        tap(app.buttons["Chatverlauf"])
        XCTAssertTrue(app.navigationBars["Chatverlauf"].waitForExistence(timeout: 4))
        XCTAssertTrue(button(containing: "Ursache und Wirkung").exists)
        XCTAssertTrue(button(containing: "Ohne Kontext").exists)
        shot("chat-history")
        tap(button(containing: "Ursache und Wirkung"))

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
            ("kamera", "Kamera", "Kamerafoto.jpg"),
            ("fotos", "Fotos", "Testfoto.jpg"),
            ("dateien", "Dateien", "Testdokument.pdf"),
        ]
        for (identifier, choice, fileName) in choices {
            launch(tab: "chat")
            tap(app.buttons["chat.add"])
            let attachmentButton = app.buttons["chat.add.\(identifier)"]
            XCTAssertTrue(attachmentButton.waitForExistence(timeout: 4))
            tap(attachmentButton)
            XCTAssertTrue(app.staticTexts[fileName].waitForExistence(timeout: 4))
            shot("chat-attachment-\(choice)")
            typeText("Analysiere diesen Anhang", into: app.textFields["chat.input"])
            tap(app.buttons["chat.send"])
            let answer = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS 'Antwort auf'"))
                .firstMatch
            XCTAssertTrue(answer.waitForExistence(timeout: 10))
            shot("chat-attachment-answer-\(choice)")
        }
    }

    func testStreamingStopRegenerateCopyNewAndClearConversation() {
        launch(tab: "chat", scenario: "longContent")
        typeText("Erzeuge eine lange Testantwort", into: app.textFields["chat.input"])
        tap(app.buttons["chat.send"])
        XCTAssertTrue(app.buttons["Antwort stoppen"].waitForExistence(timeout: 3))
        shot("chat-streaming")
        tap(app.buttons["Antwort stoppen"])
        XCTAssertTrue(app.buttons["Nachricht senden"].waitForExistence(timeout: 4))
        shot("chat-stream-cancelled")

        if app.buttons["chat.regenerate"].exists {
            tap(app.buttons["chat.regenerate"])
            // Wait for the regenerated answer to actually finish: the send
            // button returns from "stop" only once the stream has ended.
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true"),
                object: app.buttons["Nachricht senden"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 90), .completed)
        }
        UIPasteboard.general.items = []
        // Every assistant message has one, and the regenerated answer is the
        // last: the earlier ones can be scrolled out of reach by then.
        let copyButtons = app.buttons.matching(identifier: "chat.copy")
        XCTAssertGreaterThan(copyButtons.count, 0, "The assistant answer has no copy action")
        tap(copyButtons.element(boundBy: copyButtons.count - 1))
        shot("chat-copy-confirmation")
        // The visible "Kopiert" state is deliberately short-lived, and XCTest's
        // own idle wait after the tap can outlast it on a loaded hosted runner.
        // Assert the result the student depends on instead of the toast's timing.
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in UIPasteboard.general.hasStrings },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed)

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
                typeText("Fehler auslösen", into: app.textFields["chat.input"])
                tap(app.buttons["chat.send"])
                let errorStatus = app.staticTexts
                    .matching(NSPredicate(format: "label CONTAINS 'Test'"))
                    .firstMatch
                XCTAssertTrue(errorStatus.waitForExistence(timeout: 6))
            }
            shot("chat-error-\(scenario)")
        }
    }

    func testChatDuringRecordingShowsTheLiveContext() {
        launch(tab: "chat", scenario: "recording")
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
        // While the lesson is being recorded the composer swaps its context
        // picker for a fixed live badge, so the question is asked about now.
        let live = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Kontext: Aktuelle Aufnahme'"))
            .firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 5), "The chat does not show the live recording context")
        shot("chat-live-context")
        assertVisibleElementsStayOnScreen()
    }

    func testDictationNeverMovesOrResizesTheComposer() {
        launch(tab: "chat")
        let microphone = app.buttons["Frage diktieren"]
        let send = app.buttons["chat.send"]
        let input = app.textFields["chat.input"]
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
        shot("chat-dictation-stable-composer")

        tap(stop)
        XCTAssertTrue(app.buttons["Frage diktieren"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Frage diktieren"].frame, microphoneFrame)
        XCTAssertEqual(send.frame, sendFrame)
        XCTAssertEqual(input.frame, inputFrame)
    }
}
