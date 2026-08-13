import XCTest

final class SettingsUITests: EchoUITestCase {
    func testEverySettingsDestinationAndEditableControls() {
        launch(tab: "einstellungen")
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 5))
        shot("settings-index")

        openSettingsPage("Server", title: "Server")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Verbunden'")).firstMatch.exists)
        shot("settings-server")
        back()

        openSettingsPage("Stundenplan", title: "Stundenplan")
        XCTAssertTrue(app.staticTexts["Mit WebUntis verbunden"].waitForExistence(timeout: 4))
        let reminder = app.switches["Erinnerung bei Stundenbeginn"]
        tap(reminder)
        let autoStop = app.switches["Aufnahme bei Stundenende stoppen"]
        tap(autoStop)
        tap(autoStop)
        tap(app.buttons["Anmeldung ändern"])
        typeText("testschule", into: app.textFields["Schule (z. B. avs-itzehoe)"])
        typeText("testnutzer", into: app.textFields["Benutzername"])
        typeText("testpasswort", into: app.secureTextFields["Passwort"])
        tap(app.buttons["Anmelden"])
        XCTAssertTrue(app.staticTexts["Verbunden."].waitForExistence(timeout: 5))
        shot("settings-timetable")
        back()

        openSettingsPage("Aufnahme", title: "Aufnahme")
        tap(app.buttons["Blau"])
        tap(app.buttons["Bitrate"])
        tap(app.buttons["32 kbit/s"])
        tap(app.buttons["Aufnahmediagnose"])
        XCTAssertTrue(app.navigationBars["Aufnahmediagnose"].waitForExistence(timeout: 4))
        shot("settings-recording-diagnostics")
        back()
        back()

        openSettingsPage("KI", title: "KI")
        XCTAssertTrue(app.buttons["Anbieter"].waitForExistence(timeout: 4))
        shot("settings-ai")
        tap(app.buttons["Modell"])
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'GPT-5.6 Sol'")).firstMatch)
        back()

        openSettingsPage("Bibliothek", title: "Bibliothek")
        let numbering = app.switches["Seitenzahlen anpassen"]
        tap(numbering)
        tap(numbering)
        let renaming = app.switches["Bücher umbenennen"]
        tap(renaming)
        tap(renaming)
        shot("settings-library")
        back()

        openSettingsPage("App-Wechsel", title: "App-Wechsel")
        tap(app.buttons["App"])
        tap(app.buttons["Eigene URL"])
        back()
        XCTAssertTrue(app.textFields["URL-Schema"].waitForExistence(timeout: 3))
        typeText("echo-test://", into: app.textFields["URL-Schema"])
        shot("settings-quick-switch-custom")
        back()

        openSettingsPage("Über Echo", title: "Über Echo")
        XCTAssertTrue(app.staticTexts["Qwen3-ASR 1.7B"].exists)
        shot("settings-about")
        rotateAndCapture("settings-about")
    }

    func testAIProviderModelSpeedEffortAndContextCombinations() {
        launch(tab: "einstellungen")
        openSettingsPage("KI", title: "KI")

        tap(app.buttons["Anbieter"])
        tap(app.buttons["Gemini"])
        let modelDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["Modell"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [modelDisappeared], timeout: 3), .completed)
        shot("settings-ai-gemini")

        tap(app.buttons["Anbieter"])
        tap(app.buttons["ChatGPT"])
        tap(app.buttons["Modell"])
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'GPT-5.6 Luna'")).firstMatch)
        back()
        XCTAssertTrue(app.navigationBars["KI"].waitForExistence(timeout: 3))
        tap(app.buttons["Geschwindigkeit"])
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Schnell'")).firstMatch)
        tap(app.buttons["Denkaufwand"])
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Hoch'")).firstMatch)
        shot("settings-ai-chatgpt-combination")

        let increment = app.buttons["Kontextfenster"].buttons["Increment"]
        if increment.exists { increment.tap(); increment.tap() }
        shot("settings-ai-context-adjusted")
    }

    func testSettingsErrorAndOfflinePresentation() {
        for scenario in ["offline", "unauthorized", "serverError"] {
            launch(tab: "einstellungen", scenario: scenario)
            openSettingsPage("Server", title: "Server")
            shot("settings-server-\(scenario)")
            back()
            openSettingsPage("KI", title: "KI")
            let unavailable = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS 'Server nicht erreichbar'"))
                .firstMatch
            XCTAssertTrue(unavailable.waitForExistence(timeout: 6))
            shot("settings-ai-\(scenario)")
        }
    }

    private func openSettingsPage(_ row: String, title: String) {
        tap(button(containing: row))
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func back() {
        let button = app.navigationBars.buttons.firstMatch
        tap(button)
    }
}
