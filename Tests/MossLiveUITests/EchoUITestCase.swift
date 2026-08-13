import XCTest

class EchoUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        app = nil
    }

    @discardableResult
    func launch(
        tab: String = "aufnahme",
        scenario: String = "populated",
        contentSize: String = "UICTContentSizeCategoryL"
    ) -> XCUIApplication {
        app.terminate()
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

    func shot(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        assertVisibleElementsStayOnScreen(file: file, line: line)
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
        field.press(forDuration: 0.8)
        if app.menuItems["Alles auswählen"].waitForExistence(timeout: 1) {
            app.menuItems["Alles auswählen"].tap()
        } else if app.menuItems["Select All"].waitForExistence(timeout: 1) {
            app.menuItems["Select All"].tap()
        }
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

    func rotateAndCapture(_ prefix: String) {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        shot("\(prefix)-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        shot("\(prefix)-portrait")
    }
}
