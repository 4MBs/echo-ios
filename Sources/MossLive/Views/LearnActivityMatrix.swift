import SwiftUI

/// One cell of the activity matrix: a day that either saw reviews or stayed
/// quiet. The value the cell shades by is how *much* was reviewed — the
/// correctness of those reviews travels along and is spoken in the popover,
/// where it can be read instead of squinted at.
struct LearnMatrixCell: Identifiable, Hashable {
    enum Kind: Hashable {
        /// No reviews that day. Drawn as the neutral floor.
        case quiet
        /// `reviews` graded answers, `correct` their mean (0...1).
        case active(reviews: Int, correct: Double)
    }

    let day: Date
    let kind: Kind

    var id: Date { day }

    /// How strongly the cell is filled with its subject colour: quiet days
    /// keep a visible floor, and the scale saturates at a full hand of cards —
    /// a six-card day is a real study day, and a sixty-card one must not make
    /// an eight-card day look lazy.
    var intensity: Double {
        switch kind {
        case .quiet: 0
        case .active(let reviews, _): min(1, Double(reviews) / 6)
        }
    }

    /// The Kadō floor: a day with work in it never collapses into the same
    /// shade as a day without, however little was done.
    static let minimumIntensity = 0.25

    var fillOpacity: Double {
        Self.minimumIntensity + (1 - Self.minimumIntensity) * intensity
    }
}

/// One matrix row: a subject and its 30 days, in column order.
struct LearnMatrixRow: Identifiable, Equatable {
    let subject: String?
    let cells: [LearnMatrixCell]

    var id: String { subject ?? "" }
}

/// Pure shaping of the backend's `/learn/activity` answer into matrix rows —
/// SwiftUI-free so the bucketing can be unit-tested.
enum LearnMatrixModel {
    /// Rows for `subjects` (in the dashboard's order), with any subject that
    /// has activity but no cards left — work from a deleted deck — appended
    /// rather than silently dropped.
    static func rows(
        activity: BackendAPI.LearnActivity,
        subjectOrder: [String?],
        calendar: Calendar
    ) -> [LearnMatrixRow] {
        let bySubject = Dictionary(
            activity.subjects.map { ($0.subject, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let columns = columnDates(activity: activity, calendar: calendar)
        let indexForDay = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })

        func cells(for entry: BackendAPI.LearnActivity.Subject?) -> [LearnMatrixCell] {
            var cells = columns.map { LearnMatrixCell(day: $0, kind: .quiet) }
            for day in entry?.days ?? [] {
                guard let date = day.parsedDate,
                      let index = indexForDay[calendar.startOfDay(for: date)] else { continue }
                cells[index] = LearnMatrixCell(
                    day: columns[index],
                    kind: .active(reviews: day.reviews, correct: day.correct)
                )
            }
            return cells
        }

        var rows = subjectOrder.map { subject -> LearnMatrixRow in
            LearnMatrixRow(subject: subject, cells: cells(for: bySubject[subject]))
        }
        let known = Set(subjectOrder)
        for entry in activity.subjects where !known.contains(entry.subject) {
            rows.append(LearnMatrixRow(subject: entry.subject, cells: cells(for: entry)))
        }
        return rows
    }

    /// The matrix's columns: one per day from `start` through `today`, local
    /// calendar. The dates come from the server, which also grouped the days,
    /// so the two can never disagree about which day a review belongs to.
    static func columnDates(activity: BackendAPI.LearnActivity, calendar: Calendar) -> [Date] {
        let days = max(1, activity.days)
        guard let start = activity.parsedStartDate else { return [] }
        return (0 ..< days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

/// The subjects × days grid: subjects down (their colour and name fixed on
/// the left), days across in one shared horizontal scroll that opens at
/// today, one tappable cell per day.
struct LearnActivityMatrixView: View {
    let rows: [LearnMatrixRow]
    let columns: [Date]

    @State private var selection: Selected?

    struct Selected: Equatable {
        let row: LearnMatrixRow
        let cell: LearnMatrixCell
    }

    private static let cellSize: CGFloat = 26
    private static let cellSpacing: CGFloat = 4
    private static let rowSpacing: CGFloat = 8
    private static let labelWidth: CGFloat = 118

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("Noch keine Fächer mit Wiederholungen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: Theme.Space.stack) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                // The scroll side starts with the weekday header; the labels
                // start below it, level with their row.
                Color.clear.frame(height: Self.cellSize)
                ForEach(rows) { row in
                    rowLabel(row)
                        .frame(height: Self.cellSize, alignment: .center)
                }
            }
            .frame(width: Self.labelWidth, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    header
                    ForEach(rows) { row in
                        HStack(spacing: Self.cellSpacing) {
                            ForEach(row.cells) { cell in
                                cellView(cell, row: row)
                            }
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
                .padding(.vertical, 1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Self.cellSpacing) {
            ForEach(columns, id: \.self) { day in
                VStack(spacing: 0) {
                    Text(day, format: .dateTime.weekday(.narrow))
                    Text(day, format: .dateTime.day())
                        .monospacedDigit()
                }
                .font(.caption2.weight(dayIsToday(day) ? .bold : .regular))
                .foregroundStyle(dayIsToday(day) ? Theme.accent : .secondary)
                .frame(width: Self.cellSize)
            }
        }
        .frame(height: Self.cellSize, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func rowLabel(_ row: LearnMatrixRow) -> some View {
        let style = subjectStyle(for: row.subject)
        return HStack(spacing: 6) {
            Image(style.icon)
                .foregroundStyle(style.color)
                .frame(width: 16, height: 16)
            Text(row.subject?.isEmpty == false ? row.subject! : otherSubjectName)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
    }

    private func cellView(_ cell: LearnMatrixCell, row: LearnMatrixRow) -> some View {
        let style = subjectStyle(for: row.subject)
        return Button {
            if case .active = cell.kind {
                selection = Selected(row: row, cell: cell)
            }
        } label: {
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(cell.kind == .quiet ? Color(.tertiarySystemFill) : style.color)
                .opacity(cell.kind == .quiet ? 1 : cell.fillOpacity)
                .overlay {
                    if dayIsToday(cell.day) {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 1.5)
                    }
                }
                .frame(width: Self.cellSize, height: Self.cellSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cellAccessibilityLabel(cell, row: row))
        // One popover per cell, but a single shared selection: only the cell
        // the selection names presents (anchored to that cell), the rest's
        // bindings just read false.
        .popover(isPresented: isSelected(cell: cell, row: row)) {
            if let selected = selection {
                cellPopover(selected)
            }
        }
    }

    private func isSelected(cell: LearnMatrixCell, row: LearnMatrixRow) -> Binding<Bool> {
        Binding(
            get: { selection == Selected(row: row, cell: cell) },
            set: { if !$0 { selection = nil } }
        )
    }

    private func cellPopover(_ selected: Selected) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selected.cell.day, format: .dateTime.weekday(.wide).day().month())
                .font(.headline)
            if case .active(let reviews, let correct) = selected.cell.kind {
                Text("\(reviews) Karte\(reviews == 1 ? "" : "n") wiederholt")
                    .font(.subheadline)
                Text(correct.formatted(.percent.precision(.fractionLength(0))) + " richtig beantwortet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.inset)
        .frame(minWidth: 220)
        .presentationCompactAdaptation(.popover)
    }

    private func cellAccessibilityLabel(_ cell: LearnMatrixCell, row: LearnMatrixRow) -> Text {
        let name = row.subject?.isEmpty == false ? row.subject! : otherSubjectName
        let day = cell.day.formatted(date: .abbreviated, time: .omitted)
        switch cell.kind {
        case .quiet:
            return Text("\(name), \(day), keine Wiederholungen")
        case .active(let reviews, let correct):
            let share = correct.formatted(.percent.precision(.fractionLength(0)))
            return Text("\(name), \(day), \(reviews) Karten, \(share) richtig")
        }
    }

    private func dayIsToday(_ day: Date) -> Bool {
        Calendar.current.isDateInToday(day)
    }
}

#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let columns = (0 ..< 30).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }.reversed()
    let subjects: [String?] = ["Biologie", "Mathematik", "Geschichte", nil]
    let rows = subjects.map { subject in
        LearnMatrixRow(
            subject: subject,
            cells: columns.map { day in
                LearnMatrixCell(
                    day: day,
                    kind: .quiet
                )
            }
        )
    }
    .map { row in
        LearnMatrixRow(
            subject: row.subject,
            cells: row.cells.enumerated().map { index, cell in
                index % 3 == 0
                    ? LearnMatrixCell(day: cell.day, kind: .active(reviews: (index % 7) + 1, correct: 0.7))
                    : cell
            }
        )
    }
    return LearnActivityMatrixView(rows: rows, columns: Array(columns))
        .padding()
}
