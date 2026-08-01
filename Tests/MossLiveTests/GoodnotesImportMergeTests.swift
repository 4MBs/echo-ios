@testable import MossLive
import XCTest

final class GoodnotesImportMergeTests: XCTestCase {
    func testMissingTypedOCRLineReturnsBesideItsVisualNeighbours() {
        let exactTyped = [
            "Water",
            "Wildfire",
            "Population",
            "High cost of living",
            "Homelessness",
            "Natural disaster",
            "Ich libe katzen",
            "High energy cost",
            "Droughts",
            "Crime",
            "Drug addiction",
            "Ich maghäuser",
            "Tets test",
            "Warum",
        ]
        let native = (exactTyped + ["nich", "ich", "weis"]).joined(separator: "\n")
        let vision = """
        Wildfire
        Population
        High cost of living
        Homelessness
        Natural disaster
        Ich libe katzen
        High energy cost
        Droughts
        Crime
        Drug addiction
        Ich maghäuser
        Tets test
        Ich weis ninh
        Warum
        """

        let merged = LocalNoteImporter.mergeGoodnotesText(
            native: native,
            ocrText: vision,
            ocrConfidence: 0.9,
            exactTypedLines: exactTyped
        )
        let lines = merged.split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertEqual(lines.first, "Water")
        XCTAssertEqual(lines.last, "Ich weis nich")
        XCTAssertEqual(lines.filter { $0 == "Water" }.count, 1)
        XCTAssertTrue(lines.contains("Ich weis nich"))
        XCTAssertLessThan(lines.firstIndex(of: "Natural disaster")!, lines.firstIndex(of: "Ich libe katzen")!)
        XCTAssertLessThan(lines.firstIndex(of: "Tets test")!, lines.firstIndex(of: "Ich weis nich")!)
        XCTAssertLessThan(lines.firstIndex(of: "Warum")!, lines.firstIndex(of: "Ich weis nich")!)
    }

    func testLowConfidenceOCRCannotReplaceNativeOrder() {
        let native = "Water\nWildfire\nPopulation"
        let merged = LocalNoteImporter.mergeGoodnotesText(
            native: native,
            ocrText: "Population\nWildfire",
            ocrConfidence: 0.2,
            exactTypedLines: ["Water", "Wildfire", "Population"]
        )
        XCTAssertEqual(merged, native)
    }

    func testRepeatedTypedLinesAreNotCollapsed() {
        let merged = LocalNoteImporter.mergeGoodnotesText(
            native: "Hallo\nHallo\nHallo",
            ocrText: "Hallo\nHallo\nZusatz",
            ocrConfidence: 0.9,
            exactTypedLines: ["Hallo", "Hallo", "Hallo"]
        )
        XCTAssertEqual(merged.split(whereSeparator: \.isNewline).filter { $0 == "Hallo" }.count, 3)
    }
}
