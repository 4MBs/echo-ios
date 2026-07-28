import SwiftUI

/// SF Symbol + color for a school subject's icon tile and folder.
struct SubjectStyle {
    let symbol: String
    let color: Color

    /// The same glyph without its fill.
    ///
    /// For the places a symbol is drawn large and in white on the subject's own
    /// colour: at 26pt a filled glyph is a white blob, and it is the outline
    /// that reads as an atom or a leaf. Derived rather than listed a second
    /// time, because every entry below is either already an outline or a `.fill`
    /// whose base name is itself a symbol.
    var outlineSymbol: String {
        symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol
    }
}

/// A handful of subjects more than the system palette has distinct colours for.
/// Same character as the system ones — saturated, mid-brightness — so a folder
/// built from one sits beside a folder built from `.blue` without looking like
/// it came from somewhere else.
private extension Color {
    static let subjectTerracotta = Color(hue: 0.045, saturation: 0.60, brightness: 0.82)
    static let subjectAmber = Color(hue: 0.108, saturation: 0.82, brightness: 0.86)
    static let subjectSteel = Color(hue: 0.575, saturation: 0.32, brightness: 0.62)
    static let subjectPlum = Color(hue: 0.885, saturation: 0.48, brightness: 0.68)
}

/// The catch-all folder: everything recorded while no lesson was running — the
/// holidays, an evening, a free period.
let otherSubjectName = "Sonstige"

/// Best-effort keyword match from a subject name to its icon and colour.
///
/// Matched against the name the backend labels a recording with, which is
/// WebUntis' long name where it has one (`Mathematik`, `Wirtschaft/Politik`,
/// `MINT - Mittelstufe`) and the short code where it does not. Keywords are
/// tried in order, so a compound name lands on the more specific entry:
/// `Wirtschaft/Politik` is its own subject rather than either half.
func subjectStyle(for subject: String?) -> SubjectStyle {
    let fallback = SubjectStyle(symbol: "graduationcap.fill", color: .blue)
    guard let subject = subject?.lowercased(), !subject.isEmpty else {
        return SubjectStyle(symbol: "tray.full.fill", color: .gray)
    }
    let map: [(String, SubjectStyle)] = [
        ("sonstige", .init(symbol: "tray.full.fill", color: .gray)),
        // compounds first — each of these contains a keyword further down
        ("wirtschaft", .init(symbol: "chart.line.uptrend.xyaxis", color: .subjectAmber)),
        ("mint", .init(symbol: "gearshape.2.fill", color: .cyan)),
        ("förderband", .init(symbol: "sparkles", color: .yellow)),
        ("forderband", .init(symbol: "sparkles", color: .yellow)),
        ("hospitation", .init(symbol: "eye.fill", color: .subjectSteel)),
        ("mathe", .init(symbol: "x.squareroot", color: .blue)),
        ("math", .init(symbol: "x.squareroot", color: .blue)),
        ("physik", .init(symbol: "atom", color: .indigo)),
        ("chemie", .init(symbol: "testtube.2", color: .purple)),
        ("bio", .init(symbol: "leaf.fill", color: .green)),
        ("informatik", .init(symbol: "desktopcomputer", color: .subjectSteel)),
        ("deutsch", .init(symbol: "text.book.closed.fill", color: .red)),
        ("englisch", .init(symbol: "character.book.closed.fill", color: .orange)),
        ("franz", .init(symbol: "character.book.closed.fill", color: .subjectPlum)),
        ("latein", .init(symbol: "building.columns.fill", color: .subjectTerracotta)),
        ("spanisch", .init(symbol: "character.book.closed.fill", color: .yellow)),
        ("geschichte", .init(symbol: "hourglass", color: .brown)),
        ("erdkunde", .init(symbol: "globe.europe.africa.fill", color: .teal)),
        ("geo", .init(symbol: "globe.europe.africa.fill", color: .teal)),
        ("musik", .init(symbol: "music.note", color: .subjectPlum)),
        ("kunst", .init(symbol: "paintpalette.fill", color: .pink)),
        ("sport", .init(symbol: "figure.run", color: .mint)),
        ("religion", .init(symbol: "book.closed.fill", color: .indigo)),
        ("ethik", .init(symbol: "person.2.fill", color: .subjectSteel)),
        ("politik", .init(symbol: "building.columns.fill", color: .subjectAmber)),
    ]
    for (keyword, style) in map where subject.contains(keyword) {
        return style
    }
    return fallback
}

/// Settings-style list icon: white glyph on a colored rounded square.
struct IconTile: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The backend asks Gemini for plain text, but render any inline Markdown
/// that slips through instead of showing raw asterisks.
func renderedMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

/// Shared export text for a lesson (used by the detail and summary screens).
func lessonShareText(summary: String?, segments: [TranscriptSegment]) -> String {
    var parts: [String] = []
    if let summary {
        parts.append("ZUSAMMENFASSUNG\n\(summary)\n")
    }
    parts.append("TRANSKRIPT")
    parts.append(contentsOf: segments.map(\.text))
    return parts.joined(separator: "\n")
}

// MARK: - Shared list states

/// What a screen shows when a request did not work out.
///
/// Three cases, and they look different because they are different: nothing
/// answered, the server answered and said no, or something actually broke.
/// Calling all of them "Verbindung fehlgeschlagen" is wrong in two of them —
/// and offering to try again on a lesson that is simply too short to make a
/// quiz out of is worse than wrong, because the answer will be the same every
/// single time.
struct ErrorState: View {
    let error: Error
    let retry: (() async -> Void)?

    init(_ error: Error, retry: (() async -> Void)? = nil) {
        self.error = error
        self.retry = retry
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            if let retry, !isRefusal {
                Button("Erneut versuchen") { Task { await retry() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var status: Int? { (error as? BackendAPI.APIError)?.status }

    private var isOffline: Bool { Connectivity.meansUnreachable(error) }

    /// The server answered and said no. Asking again gets the same answer, so
    /// there is nothing worth putting a button under.
    private var isRefusal: Bool {
        guard let status else { return false }
        return (400 ..< 500).contains(status) && ![401, 408, 429].contains(status)
    }

    private var title: String {
        if isOffline { return "Keine Verbindung" }
        if status == 401 { return "Zugang abgelehnt" }
        if isRefusal { return "Nicht möglich" }
        return "Etwas ist schiefgelaufen"
    }

    private var symbol: String {
        if isOffline { return "wifi.slash" }
        if status == 401 { return "lock" }
        if isRefusal { return "exclamationmark.circle" }
        return "exclamationmark.triangle"
    }

    private var detail: String {
        if isOffline {
            return "Der Server ist nicht erreichbar. Gespeicherte Inhalte funktionieren weiter."
        }
        // Server messages are written as fragments; they read as sentences here.
        let text = error.localizedDescription
        return text.prefix(1).uppercased() + String(text.dropFirst())
    }
}

struct EmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        ContentUnavailableView {
            Image(systemName: icon)
        } description: {
            Text(text)
        }
    }
}

/// One lesson as a row inside its subject's folder.
///
/// The date leads, because inside a folder that already says "Mathematik" the
/// date is the only thing that tells one recording from the next — everything
/// the old row led with (the subject tile, the subject name, the room) was the
/// same on every row down the page. What follows it is the opening of the
/// summary, so the list can be read for what was taught rather than for when.
struct LessonRow: View {
    let info: BackendAPI.LessonInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.body)
                    .lineLimit(1)
                Text(timeLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if info.hasAudio {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            secondLine
        }
        .padding(.vertical, 3)
    }

    /// When it started and how long it ran. Not the room: inside a folder that
    /// is the same on nearly every row, and the lesson's own page says it.
    private var timeLine: String {
        info.startedAt.formatted(date: .omitted, time: .shortened) + " · " + durationText
    }

    private var durationText: String {
        let minutes = Int(info.durationSeconds) / 60
        return minutes > 0 ? "\(minutes) Min" : "\(Int(info.durationSeconds)) s"
    }

    /// Two lines of the summary — or an honest word about there not being one,
    /// which is a state worth seeing at a glance rather than a blank row.
    @ViewBuilder
    private var secondLine: some View {
        if let excerpt = info.summaryExcerpt, !excerpt.isEmpty {
            Text(excerpt)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        } else {
            Text(info.segmentCount > 0 ? "Noch keine Zusammenfassung" : "Kein Transkript")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
