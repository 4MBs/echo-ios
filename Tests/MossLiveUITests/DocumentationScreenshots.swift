import XCTest

/// Not a behaviour test: this photographs the screens shown in the README and
/// docs/, from the same deterministic fixtures the rest of the suite uses, so
/// the documentation can be refreshed without a physical iPad. The images are
/// XCTest attachments; `screenshots.yml` exports and renames them.
///
/// Landscape, because Echo is an iPad app held in landscape and a portrait
/// capture of a 13" screen is mostly empty space in a README.
final class DocumentationScreenshots: EchoUITestCase {
    func testCaptureDocumentationScreens() {
        capture(name: "recording", tab: "aufnahme", scenario: "recording")
        capture(name: "lessons", tab: "stunden", scenario: "populated")
        capture(name: "learn", tab: "lernen", scenario: "populated")
        capture(name: "chat", tab: "chat", scenario: "populated")
        capture(name: "library", tab: "bibliothek", scenario: "populated")
    }

    private func capture(name: String, tab: String, scenario: String) {
        launch(tab: tab, scenario: scenario)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        // The fake backend answers in 50 ms, but the first frame after a
        // rotation still has to lay out and animate in. A screenshot taken
        // mid-transition is the one thing that would make these useless.
        settle(seconds: 3)
        shot(name)
    }

    private func settle(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
