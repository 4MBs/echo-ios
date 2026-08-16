import XCTest

@testable import MossLive

/// The matrix's shaping logic: which cell a review lands in, and how strongly
/// a cell is filled. Pure model tests — the grid drawing is verified by the
/// UI tests against the UITestRuntime fake.
final class LearnMatrixTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
    }

    private func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func activity(start: Date, today: Date, subjects: [BackendAPI.LearnActivity.Subject]) -> BackendAPI
        .LearnActivity {
        BackendAPI.LearnActivity(
            start: iso(start),
            today: iso(today),
            days: 30,
            subjects: subjects
        )
    }

    private func day(_ date: Date, reviews: Int, correct: Double) -> BackendAPI.LearnActivity.Day {
        BackendAPI.LearnActivity.Day(date: iso(date), reviews: reviews, correct: correct)
    }

    func testColumnsRunOnePerDayEndingToday() {
        let columns = LearnMatrixModel.columnDates(
            activity: activity(
                start: date(2026, 7, 18),
                today: date(2026, 8, 16),
                subjects: []
            ),
            calendar: calendar
        )
        XCTAssertEqual(columns.count, 30)
        XCTAssertEqual(columns.first, date(2026, 7, 18))
        XCTAssertEqual(columns.last, date(2026, 8, 16))
    }

    func testReviewsLandInTheirDayAndGapsStayQuiet() {
        let today = date(2026, 8, 16)
        let activity = self.activity(
            start: date(2026, 7, 18),
            today: today,
            subjects: [
                BackendAPI.LearnActivity.Subject(
                    subject: "Biologie",
                    days: [day(today, reviews: 3, correct: 0.8), day(date(2026, 8, 13), reviews: 5, correct: 0.5)]
                )
            ]
        )
        let rows = LearnMatrixModel.rows(activity: activity, subjectOrder: ["Biologie"], calendar: calendar)
        XCTAssertEqual(rows.count, 1)
        let cells = rows[0].cells
        XCTAssertEqual(cells.count, 30)
        XCTAssertEqual(cells.last?.kind, .active(reviews: 3, correct: 0.8))
        XCTAssertEqual(cells.first?.kind, .quiet)
        // The gap between the two study days stayed quiet, on the right date.
        XCTAssertEqual(cells[27].day, date(2026, 8, 14))
        XCTAssertEqual(cells[27].kind, .quiet)
    }

    func testRowsFollowTheDashboardOrderAndAppendActivityOnlySubjects() {
        let activity = self.activity(
            start: date(2026, 7, 18),
            today: date(2026, 8, 16),
            subjects: [
                BackendAPI.LearnActivity.Subject(
                    subject: "Physik",
                    days: [day(date(2026, 8, 16), reviews: 1, correct: 1)]
                ),
                BackendAPI.LearnActivity.Subject(
                    subject: "Biologie",
                    days: [day(date(2026, 8, 16), reviews: 2, correct: 1)]
                )
            ]
        )
        let rows = LearnMatrixModel.rows(activity: activity, subjectOrder: ["Biologie"], calendar: calendar)
        XCTAssertEqual(rows.map(\.subject), ["Biologie", "Physik"])
    }

    func testASingleCardNeverCollapsesIntoAnIdleDay() {
        let cell = LearnMatrixCell(day: date(2026, 8, 16), kind: .active(reviews: 1, correct: 0))
        XCTAssertEqual(cell.fillOpacity, LearnMatrixCell.minimumIntensity, accuracy: 0.01)
        // A full hand of cards is the ceiling; more cannot get darker.
        let heavy = LearnMatrixCell(day: date(2026, 8, 16), kind: .active(reviews: 12, correct: 1))
        XCTAssertEqual(heavy.fillOpacity, 1)
        XCTAssertEqual(LearnMatrixCell(day: date(2026, 8, 16), kind: .quiet).fillOpacity, 0)
    }

    func testUnknownDatesAndGarbageAreIgnoredRatherThanCrashing() {
        let garbage = BackendAPI.LearnActivity(
            start: "not-a-date",
            today: "2026-08-16",
            days: 30,
            subjects: [
                BackendAPI.LearnActivity.Subject(
                    subject: nil,
                    days: [BackendAPI.LearnActivity.Day(date: "2026-08-16", reviews: 2, correct: 1)]
                )
            ]
        )
        // Unparseable start: no columns, no crash.
        XCTAssertEqual(LearnMatrixModel.columnDates(activity: garbage, calendar: calendar), [])
        let validStart = BackendAPI.LearnActivity(
            start: "2026-07-18",
            today: "2026-08-16",
            days: 30,
            subjects: [BackendAPI.LearnActivity.Subject(
                subject: nil,
                days: [
                    BackendAPI.LearnActivity.Day(date: "garbage", reviews: 2, correct: 1),
                    BackendAPI.LearnActivity.Day(date: "2026-05-01", reviews: 9, correct: 1)
                ]
            )]
        )
        let rows = LearnMatrixModel.rows(activity: validStart, subjectOrder: [nil], calendar: calendar)
        XCTAssertTrue(rows[0].cells.allSatisfy { $0.kind == .quiet })
    }
}
