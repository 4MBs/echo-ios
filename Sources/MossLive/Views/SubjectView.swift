import SwiftUI

/// One subject, opened from the Stunden grid: what it adds up to, and every
/// recording of it as something you can read.
///
/// This was an inset-grouped `List` of rows that led with their date. The date
/// is the one thing every row in a folder called "Mathematik" already shares a
/// shape with — twelve lines of *Di, 12. Okt*, all the same length, all the same
/// weight — so the list was sorted by the very thing it was hardest to tell
/// apart by. The lesson's topic leads now, in the size a heading is, and the
/// date moves down to the line that carries the length with it.
///
/// The heading is one line and never two. It is the topic the summarizer
/// writes, three or four words, so a column of rows is a column of short
/// headings with air between them — not the page of wrapped bold type it was
/// when the heading was the first *sentence* of a summary, which is what this
/// looked like the first time and why it did not look like anything.
///
/// Two more things follow. The rows are tall enough that one column of them
/// wastes an iPad, so past `twoColumnWidth` the list is cut in half and set
/// side by side — still read top to bottom, left column first, newest first.
/// And a `List` is gone, which takes swipe-to-delete and the edit button with
/// it: deleting a lesson is a long press on its row now, and it asks first,
/// because it takes the transcript and the recording with it.
struct SubjectView: View {
    let api: BackendAPI
    let folder: SubjectFolder
    let onChanged: () async -> Void

    @State private var lessons: [BackendAPI.LessonInfo]
    @State private var actionError: String?
    /// The row whose context menu asked for a deletion, held until it is
    /// confirmed. Also what the dialog is presented from.
    @State private var pendingDelete: BackendAPI.LessonInfo?

    /// Where a second column stops crowding the rows. A row is a heading, a
    /// meta line and a line of summary; below this, two of them side by side
    /// wrap the heading of every single one.
    ///
    /// Measured off the actual width rather than asked of the size class:
    /// iPadOS 26 windows resize freely, so there is no discrete "compact" state
    /// left to branch on.
    private static let twoColumnWidth: CGFloat = 700
    /// And how many rows are worth cutting in half. Two cards holding one row
    /// each is not a second column, it is the same list drawn twice as wide.
    private static let twoColumnMinimumRows = 4

    init(api: BackendAPI, folder: SubjectFolder, onChanged: @escaping () async -> Void) {
        self.api = api
        self.folder = folder
        self.onChanged = onChanged
        _lessons = State(initialValue: folder.lessons)
    }

    /// Newest first, and flat: the rows carry their own date, so a header per
    /// day would be one line of chrome per lesson in a list where most days
    /// hold exactly one.
    private var ordered: [BackendAPI.LessonInfo] {
        lessons.sortedNewestFirst
    }

    var body: some View {
        Group {
            if lessons.isEmpty {
                empty
            } else {
                board
            }
        }
        // No title. The page is opened by tapping a folder that says the
        // subject's name, so a glass capsule repeating it sits between the
        // header and the top of the screen saying nothing — the same reason the
        // lesson page has no title either. The bar stays for the back button.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Stunde löschen?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { lesson in
            Button("Löschen", role: .destructive) {
                Task { await delete(lesson) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { lesson in
            Text(
                "\(lesson.startedAt.formatted(date: .long, time: .shortened)) — "
                    + "Transkript und Aufnahme werden vom Server gelöscht."
            )
        }
        .alert(
            "Stunde konnte nicht gelöscht werden",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - The board

    private var board: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 26) {
                    SubjectHoursHeader(total: totalSeconds, week: weekSeconds)
                    columns(width: geo.size.width)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 36)
                // A deletion re-cuts the columns, so rows move between the two
                // cards. `List` animated that itself; here it has to be asked.
                .animation(.smooth(duration: 0.3), value: lessons.count)
            }
        }
        .groupedScreen()
    }

    private func columns(width: CGFloat) -> some View {
        let rows = ordered
        let wide = width >= Self.twoColumnWidth && rows.count >= Self.twoColumnMinimumRows
        let split = splitIntoColumns(rows, count: wide ? 2 : 1)
        return HStack(alignment: .top, spacing: 24) {
            ForEach(Array(split.enumerated()), id: \.offset) { _, column in
                SubjectLessonCard(api: api, lessons: column) { pendingDelete = $0 }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label {
                Text("Noch keine Aufnahmen")
            } icon: {
                Image(subjectStyle(for: folder.name).icon)
                    .resizable()
                    .scaledToFit()
            }
        } description: {
            Text(folder.isOther
                ? "Aufnahmen außerhalb des Stundenplans landen hier."
                : "Nimm eine Stunde in \(folder.name) auf, dann erscheint sie hier.")
        }
        .groupedScreen()
    }

    // MARK: - What the subject adds up to

    /// Every recording in this folder, in seconds.
    ///
    /// The lesson's own length, the same number its row prints — a header that
    /// disagreed with the sum of the rows under it would be worse than no
    /// header, and somebody will add them up.
    private var totalSeconds: Double {
        lessons.reduce(0) { $0 + $1.durationSeconds }
    }

    /// The part of that which was recorded in the current week. The calendar's
    /// own week, so it starts on Monday here and would start on Sunday for a
    /// device set to a locale where it does.
    private var weekSeconds: Double {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return 0 }
        return lessons
            .filter { week.contains($0.startedAt) }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    // MARK: - Deleting

    /// Gone from the list first, restored if the server refuses.
    ///
    /// The row used to wait for a round trip before it moved, so letting go of
    /// a swipe was followed by a pause with the row sitting half open — over
    /// Tailscale, a long one. No animation can be made to feel smooth with a
    /// network request in front of it.
    ///
    /// Nothing is wrapped in `withAnimation` here: the board carries an
    /// `.animation(_:value:)` keyed on the count, which animates the removal
    /// whichever thread this ends up mutating the state from.
    private func delete(_ lesson: BackendAPI.LessonInfo) async {
        let previous = lessons
        lessons.removeAll { $0.id == lesson.id }
        do {
            try await api.deleteLesson(id: lesson.id)
            BackendAPI.purgeCachedAudio(id: lesson.id)
            await onChanged()
        } catch {
            lessons = previous
            actionError = error.localizedDescription
        }
    }
}

// MARK: - The header

/// The two figures a subject can be summed up by: everything recorded in it,
/// and what of that was this week.
///
/// Sized to its own content and centred rather than stretched across the page.
/// It is a caption on the list, not a section of it, and a pill holding two
/// short numbers at either end of a 1000pt bar reads as a bar with a hole in it.
private struct SubjectHoursHeader: View {
    let total: Double
    let week: Double

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                stat("Gesamt", seconds: total)
                Divider().frame(height: 44)
                stat("Diese Woche", seconds: week)
            }
            .padding(.vertical, 14)
            .cardSurface(cornerRadius: 20)
            Spacer(minLength: 0)
        }
    }

    private func stat(_ caption: String, seconds: Double) -> some View {
        let amount = hoursLabel(seconds)
        return VStack(alignment: .leading, spacing: 3) {
            // `tracking` belongs to Text and `textCase` to View, so they have
            // to be applied in that order or the second one is unreachable.
            Text(caption)
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(amount.value)
                    .font(.title.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(amount.unit)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 26)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(amount.value) \(amount.unit)")
    }
}

// MARK: - A column of lessons

/// One column of the board: rows stacked into a single card, hairlines between
/// them.
///
/// A card per column rather than a card per row. Ten separate cards down a page
/// is ten shadows and nine gaps of background between things that belong to
/// each other; one card with rules in it is a list, which is what this is.
private struct SubjectLessonCard: View {
    let api: BackendAPI
    let lessons: [BackendAPI.LessonInfo]
    let onDelete: (BackendAPI.LessonInfo) -> Void

    private static let corner: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                NavigationLink {
                    LessonDetailView(api: api, info: lesson)
                } label: {
                    SubjectLessonRow(info: lesson)
                }
                .buttonStyle(RowPressStyle())
                .contextMenu {
                    Button(role: .destructive) {
                        onDelete(lesson)
                    } label: {
                        Label("Stunde löschen", systemImage: "trash")
                    }
                }
                if index < lessons.count - 1 {
                    // Inset to the rows' own text margin, so the rule starts
                    // where the type does rather than at the card's edge.
                    Divider().padding(.horizontal, 28)
                }
            }
        }
        .cardSurface(cornerRadius: Self.corner)
        // The card's own corners have to cut the rows as well, or the highlight
        // under a pressed first row squares off the top of the card.
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
    }
}

/// A row that answers the finger without moving.
///
/// `PressableCardStyle` dips the whole tile, which is right for a folder with
/// air around it and wrong here: a row that shrinks pulls away from the
/// hairlines it sits between. It lights up instead.
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.06 : 0))
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - A lesson

/// One recording, led by what was taught in it.
///
/// Three lines: the topic, then when it was and how long it ran, then the
/// opening of the summary. `title` cannot head it — that is the timetable's
/// label, `Physik · Raum 117`, identical on every row in the folder — so the
/// heading is the topic the summarizer writes as the summary's first line.
///
/// **The heading is one line, always.** It is the whole reason the page reads
/// as a list rather than as a page of bold text: three or four words at the
/// top of each row, the same shape every time. A lesson summarized before the
/// server asked for a topic has none, and falls back to the opening sentence
/// of its summary — prose in a heading's place, which is exactly what
/// `scripts/backfill_topics.py` exists to fix. A lesson with no summary at all
/// falls back to its timetable label or subject; only a completely unnamed
/// lesson uses its date and moves the date out of the metadata line.
private struct SubjectLessonRow: View {
    let info: BackendAPI.LessonInfo

    /// What the three lines say. The topic and the excerpt are two fields when
    /// the server wrote a topic and one field cut in two when it did not, so
    /// the row asks once and lays out the answer rather than branching twice.
    private struct Lines {
        let headline: String
        let detail: String?
        /// The heading is the date because there was no topic, timetable label,
        /// or subject, which is what moves the date out of the meta line.
        let dated: Bool
    }

    private var lines: Lines {
        let detail = info.topic?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? info.summaryExcerpt
            : lessonTopic(from: info.summaryExcerpt)?.detail
        return Lines(headline: info.displayTitle, detail: detail, dated: info.usesDateDisplayTitle)
    }

    var body: some View {
        let lines = self.lines
        return VStack(alignment: .leading, spacing: 5) {
            Text(lines.headline)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                // A long topic gives up size rather than its tail: the last
                // words of "Ursachen der Französischen Revolution" are the ones
                // that say which lesson this is. A quarter is enough to carry
                // six German words across an iPhone's single column, which is
                // the narrowest the board ever gets.
                .minimumScaleFactor(0.75)
            meta(datedHeadline: lines.dated)
            detail(lines)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        // The row is tappable across its whole width, not only where its text
        // happens to reach.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// When it was and how long it ran. Not the room and not the teacher:
    /// inside a folder both are the same on nearly every row, and the lesson's
    /// own page says them.
    private func meta(datedHeadline: Bool) -> some View {
        HStack(spacing: 7) {
            if let subject = info.displaySubject {
                Text(subject)
                Text("·")
            }
            Text(datedHeadline ? timeText : dateText)
            Text("·")
            Text(lessonDurationText(info.durationSeconds))
            if info.hasAudio {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Mit Aufnahme")
            }
        }
        // A step below the body size the rest of the app uses. The heading is
        // what the row is for, and at `.subheadline` the three lines were close
        // enough in size that none of them led — the design this comes from
        // sets its heading about half again its body text.
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The opening of the summary — or an honest word about there being none,
    /// which is a state worth seeing at a glance rather than a row that ends
    /// early for no visible reason.
    @ViewBuilder
    private func detail(_ lines: Lines) -> some View {
        if let line = lines.detail, !line.isEmpty {
            Text(line)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if lines.dated {
            Text(info.segmentCount > 0 ? "Noch keine Zusammenfassung" : "Kein Transkript")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// "12. Okt" — the day, next to the length.
    private var dateText: String {
        info.startedAt.formatted(.dateTime.day().month(.abbreviated))
    }

    private var timeText: String {
        info.startedAt.formatted(date: .omitted, time: .shortened)
    }

}

// MARK: - Numbers the screen prints

/// How long a lesson ran: "1 Std 24 Min", "52 Min", "40 s".
func lessonDurationText(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    guard minutes > 0 else { return "\(Int(seconds)) s" }
    guard minutes >= 60 else { return "\(minutes) Min" }
    let rest = minutes % 60
    return rest == 0 ? "\(minutes / 60) Std" : "\(minutes / 60) Std \(rest) Min"
}

/// Recorded time as the header sets it: an amount and its unit, kept apart so
/// the two can be typeset at different weights.
///
/// Hours to one decimal, because a subject is measured in dozens of them and
/// the second digit is the one that moves. Under an hour it is minutes: "0,3
/// Std" is a figure nobody reads as twenty minutes.
func hoursLabel(_ seconds: Double) -> (value: String, unit: String) {
    guard seconds >= 3600 else {
        return (String(Int((seconds / 60).rounded())), "Min")
    }
    return ((seconds / 3600).formatted(.number.precision(.fractionLength(1))), "Std")
}

/// The list cut into columns that are read one after another: the first column
/// holds the top of the list, the second continues it.
///
/// Not dealt out alternately. The rows are in date order and a reader goes down
/// them, so alternating would make every second lesson a jump across the page.
func splitIntoColumns<Element>(_ items: [Element], count: Int) -> [[Element]] {
    guard count > 1, items.count > 1 else { return items.isEmpty ? [] : [items] }
    let perColumn = Int((Double(items.count) / Double(count)).rounded(.up))
    return stride(from: 0, to: items.count, by: perColumn).map {
        Array(items[$0 ..< Swift.min($0 + perColumn, items.count)])
    }
}

#Preview {
    VStack(spacing: 26) {
        SubjectHoursHeader(total: 513_000, week: 15120)
        SubjectHoursHeader(total: 2400, week: 0)
    }
    .padding(20)
    .groupedScreen()
}
