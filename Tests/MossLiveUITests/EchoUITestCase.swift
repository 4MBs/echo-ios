import XCTest

class EchoUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    @discardableResult
    func launch(
        tab: String = "aufnahme",
        scenario: String = "populated",
        contentSize: String = "UICTContentSizeCategoryL"
    ) -> XCUIApplication {
        if app.state == .runningForeground
            || app.state == .runningBackground
            || app.state == .runningBackgroundSuspended {
            app.terminate()
        }
        app = XCUIApplication()
        app.launchArguments = [
            "-UITesting",
            "-UITestScenario", scenario,
            "-UITestTab", tab,
            "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE",
            "-UIPreferredContentSizeCategoryName", contentSize,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func tap(_ element: XCUIElement, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing element: \(element)", file: file, line: line)
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    func replaceText(_ field: XCUIElement, with value: String) {
        focus(field)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100))
        field.typeText(value)
    }

    func typeText(_ value: String, into field: XCUIElement) {
        focus(field)
        field.typeText(value)
    }

    private func focus(_ field: XCUIElement) {
        tap(field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func assertVisibleElementsStayOnScreen(file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        guard window.exists else { return }
        let bounds = window.frame.insetBy(dx: -2, dy: -2)
        let controlTypes: [XCUIElement.ElementType] = [
            .button, .textField, .secureTextField, .searchField, .switch, .slider, .stepper, .picker, .link,
        ]
        let controls = controlTypes.flatMap {
            window.descendants(matching: $0).allElementsBoundByIndex
        }
        for control in controls where control.isHittable && !control.frame.isEmpty {
            XCTAssertTrue(
                bounds.intersects(control.frame),
                "Visible control is outside the window: \(control)",
                file: file,
                line: line
            )
        }
    }

    func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The seeded Mathematik lesson, open and ready for its toolbar actions.
    func openLesson() {
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

    /// Compact widths move the lesson's toolbar actions into the system "More"
    /// menu, so an action is either on the bar or one level inside it.
    func tapToolbarAction(_ label: String) {
        let action = app.buttons[label]
        if action.exists {
            tap(action)
            return
        }

        tap(app.buttons["More"])
        tap(app.buttons[label])
    }

    func rotateAndCapture(_ prefix: String) {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        shot("\(prefix)-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        shot("\(prefix)-portrait")
    }
}
