@testable import MossLive
import UIKit
import XCTest

/// The subject icons are asset names now, not SF Symbols, and a wrong asset name
/// is a silent blank square rather than a build error. These are the check that
/// turns that into a red test.
final class SubjectStyleTests: XCTestCase {
    /// Every subject the keyword matcher knows about, plus the two it falls back
    /// to. Written as the strings the backend actually labels recordings with —
    /// WebUntis' long names — so this also covers the matcher itself.
    private static let subjects: [String?] = [
        "Deutsch", "Mathematik", "Englisch", "Französisch", "Latein (2. FS)",
        "Spanisch", "Biologie", "Chemie", "Physik", "Informatik", "Geschichte",
        "Erdkunde", "Wirtschaft/Politik", "Politik", "Musik", "Kunst", "Sport",
        "Religion", "Ethik", "MINT - Mittelstufe", "Förderband", "Hospitation",
        "Sonstige",
        // the two fallbacks: a subject with no rule, and no subject at all
        "Darstellendes Spiel", nil,
    ]

    func testEverySubjectIconIsInTheAssetCatalog() {
        for subject in Self.subjects {
            let icon = subjectStyle(for: subject).icon
            XCTAssertNotNil(
                UIImage(named: icon),
                "no image set named \(icon) — subject \(subject ?? "nil")"
            )
        }
    }

    /// The compounds have to be matched before their parts, or `Wirtschaft/
    /// Politik` lands on whichever of the two the list happens to reach first.
    func testCompoundSubjectsBeatTheirParts() {
        XCTAssertEqual(subjectStyle(for: "Wirtschaft/Politik").icon, subjectStyle(for: "Wirtschaft").icon)
        XCTAssertNotEqual(subjectStyle(for: "Wirtschaft/Politik").icon, subjectStyle(for: "Politik").icon)
    }
}
