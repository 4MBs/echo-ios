import XCTest

final class ShellAndStateUITests: EchoUITestCase {
    func testEveryPrimaryDestinationLaunchesAndRotates() {
        let destinations = ["aufnahme", "stunden", "bibliothek", "chat", "einstellungen"]
        for tab in destinations {
            launch(tab: tab)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
            switch tab {
            case "aufnahme": XCTAssertTrue(app.buttons["Aufnahme starten"].exists)
            case "stunden": XCTAssertTrue(app.navigationBars["Stunden"].exists)
            case "bibliothek": XCTAssertTrue(app.navigationBars["Bibliothek"].exists)
            case "chat": XCTAssertTrue(app.buttons["Chatverlauf"].exists)
            default: XCTAssertTrue(app.navigationBars["Einstellungen"].exists)
            }
            shot("shell-\(tab)-portrait")
            assertVisibleElementsStayOnScreen()
        }
        launch(tab: "aufnahme")
        rotateAndCapture("shell-recording")
    }

    func testRecordingIdleActiveReconnectingAndFailureStates() {
        launch(tab: "aufnahme")
        shot("recording-idle")
        tap(app.buttons["Aufnahme starten"])
        XCTAssertTrue(app.buttons["Aufnahme beenden"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'transkribiert'")).firstMatch.exists)
        shot("recording-active")
        tap(app.buttons["Aufnahme beenden"])
        XCTAssertTrue(app.buttons["Aufnahme starten"].waitForExistence(timeout: 3))

        launch(tab: "aufnahme", scenario: "reconnecting")
        let offlineNotice = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Offline:'"))
            .firstMatch
        XCTAssertTrue(offlineNotice.waitForExistence(timeout: 3))
        shot("recording-reconnecting")

        launch(tab: "aufnahme", scenario: "serverError")
        XCTAssertTrue(app.staticTexts["Deterministischer Testfehler."].waitForExistence(timeout: 3))
        shot("recording-server-error")
    }

    func testEmptyLoadingOfflineUnauthorizedAndLongContentMatrix() {
        executionTimeAllowance = 600
        let states = ["empty", "loading", "offline", "unauthorized", "serverError", "longContent"]
        let tabs = ["stunden", "bibliothek", "chat"]
        for state in states {
            for tab in tabs {
                launch(tab: tab, scenario: state)
                XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
                shot("state-\(state)-\(tab)")
            }
        }
    }

    func testExtraLargeTextDoesNotHidePrimaryControls() {
        launch(tab: "chat", contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.add"].exists)
        XCTAssertTrue(app.buttons["chat.send"].exists)
        shot("chat-accessibility-xxxl")
    }

    func testAccessibilityAuditOnEveryPrimaryDestination() throws {
        for tab in ["aufnahme", "stunden", "bibliothek", "chat", "einstellungen"] {
            launch(tab: tab)
            try app.performAccessibilityAudit(
                for: [.dynamicType, .hitRegion, .textClipped, .sufficientElementDescription]
            ) { issue in
                // iPadOS reports visually intact system-sidebar labels as
                // clipped because their AX node uses the row's full 52-point
                // frame. Suppress only that identified system-row false
                // positive; all app content remains audited for clipping.
                let sidebarLabels: Set<String> = [
                    "Aufnahme", "Stunden", "Bibliothek", "Chat mit KI", "Einstellungen",
                ]
                let isSystemSidebarNode = issue.element?.identifier.hasPrefix("tab.") == true
                    || sidebarLabels.contains(issue.element?.label ?? "")
                return issue.auditType == .textClipped && isSystemSidebarNode
            }
            shot("accessibility-audit-\(tab)")
        }
    }

    func testLiveAnswerLoadingSuccessRetryAndCopy() {
        launch(tab: "aufnahme", scenario: "recording")
        tap(app.buttons["KI-Antwort zu den letzten Sekunden"])
        XCTAssertTrue(app.staticTexts["Denkt nach…"].waitForExistence(timeout: 3))
        shot("live-answer-loading")
        let answer = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Testantwort fasst'"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        shot("live-answer-success")
        tap(app.buttons["Kopieren"])
        tap(app.buttons["Neu fragen"])
        XCTAssertTrue(app.staticTexts["Denkt nach…"].waitForExistence(timeout: 3))
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
    }
}
