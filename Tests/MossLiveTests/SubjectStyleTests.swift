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

    /// A subject that matched no keyword must not come back looking like one
    /// that did. Catches a fallback accidentally sharing Mathematik's blue.
    func testFallbackIsDistinctFromEveryKnownSubject() {
        let fallback = subjectStyle(for: "Darstellendes Spiel")
        for subject in Self.subjects.compactMap({ $0 }) where subject != "Darstellendes Spiel" {
            let known = subjectStyle(for: subject)
            XCTAssertFalse(
                known.tint.red == fallback.tint.red
                    && known.tint.green == fallback.tint.green
                    && known.tint.blue == fallback.tint.blue,
                "\(subject) has the same card colour as an unrecognised subject"
            )
        }
    }

    /// The compounds have to be matched before their parts, or `Wirtschaft/
    /// Politik` lands on whichever of the two the list happens to reach first.
    func testCompoundSubjectsBeatTheirParts() {
        XCTAssertEqual(subjectStyle(for: "Wirtschaft/Politik").icon, subjectStyle(for: "Wirtschaft").icon)
        XCTAssertNotEqual(subjectStyle(for: "Wirtschaft/Politik").icon, subjectStyle(for: "Politik").icon)
    }

    /// White type sits on the foot of every card. The scrim is what makes that
    /// legible on the bright ones, so it has to actually reach the ratio.
    func testEveryCardCarriesWhiteTextAtThreeToOne() {
        for subject in Self.subjects {
            let tint = subjectStyle(for: subject).tint
            let shade = tint.scrim()
            let scaled = 1 - shade.bottom
            func channel(_ value: Double) -> Double {
                let component = value * scaled
                return component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * channel(tint.red)
                + 0.7152 * channel(tint.green)
                + 0.0722 * channel(tint.blue)
            let ratio = 1.05 / (luminance + 0.05)
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "white on \(subject ?? "nil") is \(ratio):1 even with its scrim"
            )
        }
    }
}
