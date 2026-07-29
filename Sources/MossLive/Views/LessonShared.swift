import Foundation
import SwiftUI

/// A subject's colour, kept as the numbers it was chosen as.
///
/// Not a `Color`. Every screen that draws a subject needs a *variant* of its
/// colour — a card gradient, a deeper ink for a glyph sitting on a pale wash of
/// the same hue — and the only way back out of a `Color` is
/// `UIColor(color).getHue(...)`, which resolves against whatever trait
/// collection happens to be current. Keeping the three numbers makes all of it
/// arithmetic instead of a round trip.
struct SubjectTint {
    let hue: Double
    let saturation: Double
    let brightness: Double

    init(_ hue: Double, _ saturation: Double, _ brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

/// SF Symbol + colour for a school subject's folder and card.
struct SubjectStyle {
    let symbol: String
    let tint: SubjectTint

    var color: Color { tint.color }

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

extension SubjectTint {
    /// The subject as a card: its own value at the top, a deeper cut of the same
    /// hue at the bottom.
    ///
    /// The first version of this flattened every subject to a single value
    /// capped at 0.70 brightness, because white text on a saturated fill needs
    /// somewhere dark to sit. It bought that legibility with the colour itself —
    /// a wheel of muted slabs, half of which read as the same slab.
    ///
    /// A gradient buys both. The top is the palette's own value, untouched:
    /// that is where the eye lands, and it is what makes a grid findable. The
    /// bottom is what gets capped, and the bottom is exactly where the name and
    /// the count are.
    func cardFill(contrast: ColorSchemeContrast = .standard) -> LinearGradient {
        let increased = contrast == .increased
        let top = increased ? min(brightness, 0.78) : brightness
        let deeper = min(1, saturation + 0.08)
        let bottom = Self.legibleBottom(
            hue: hue,
            saturation: deeper,
            start: min(top - 0.24, 0.72),
            target: increased ? 4.6 : 3.2
        )
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: saturation, brightness: top),
                Color(hue: hue, saturation: deeper, brightness: bottom),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The colour taken down far enough to be read as a mark on a pale wash of
    /// itself. The folder tiles draw the glyph in the subject's colour over that
    /// same colour at a third opacity; at 0.96 brightness the two are the same
    /// value and the glyph vanishes into the card.
    var ink: Color {
        Color(hue: hue, saturation: min(1, saturation + 0.10), brightness: min(brightness, 0.58))
    }

    /// How light the bottom of a card may be: walk the brightness down until
    /// white bold type clears `target`, rather than stopping at one number
    /// picked for the average hue.
    ///
    /// It has to be luminance and not brightness, and the difference is the
    /// whole reason this exists. A gold at 0.68 brightness is nearly twice as
    /// luminous as a blue at the same number, so the flat cap this replaces let
    /// every yellow through at 2.8:1 while taking the blues far darker than they
    /// ever needed to go.
    private static func legibleBottom(
        hue: Double,
        saturation: Double,
        start: Double,
        target: Double
    ) -> Double {
        var brightness = start
        while brightness > 0.24 {
            let ratio = 1.05 / (luminance(hue: hue, saturation: saturation, brightness: brightness) + 0.05)
            if ratio >= target { return brightness }
            brightness -= 0.02
        }
        return 0.24
    }

    /// WCAG relative luminance of an HSB triple.
    private static func luminance(hue: Double, saturation: Double, brightness: Double) -> Double {
        let (red, green, blue) = rgb(hue: hue, saturation: saturation, brightness: brightness)
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The standard HSB-to-RGB conversion, written out so these numbers stay
    /// fixed rather than depending on how a `UIColor` resolves itself.
    private static func rgb(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> (Double, Double, Double) {
        guard saturation > 0 else { return (brightness, brightness, brightness) }
        let sector = (hue - hue.rounded(.down)) * 6
        let fraction = sector - sector.rounded(.down)
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        switch Int(sector) {
        case 0: return (brightness, rising, low)
        case 1: return (falling, brightness, low)
        case 2: return (low, brightness, rising)
        case 3: return (low, falling, brightness)
        case 4: return (rising, low, brightness)
        default: return (brightness, low, falling)
        }
    }
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
///
/// The colours used to be the system palette plus four of our own. The system
/// set has thirteen distinct entries and the timetable needs twenty-two, so six
/// subjects shared a colour outright — Informatik, Ethik and Hospitation were
/// all the same grey-blue, Musik and Französisch the same plum — and several
/// more were a nudge apart at tile size: `.cyan`, `.teal` and `.mint` read as
/// one colour, and so did `.blue` and `.indigo`.
///
/// These were placed by measuring instead. No two are closer than 21 units of
/// CIE76 — roughly the distance at which two tiles stop being the same tile —
/// and every one of them clears 3:1 against white bold type at the foot of its
/// card, which is the ratio Apple's contrast table asks for.
func subjectStyle(for subject: String?) -> SubjectStyle {
    // A subject nobody wrote a rule for: a pale blue-grey, so it reads as "not
    // one of the known ones" rather than as Mathematik.
    let fallback = SubjectStyle(symbol: "graduationcap.fill", tint: .init(0.630, 0.26, 0.88))
    let catchAll = SubjectStyle(symbol: "tray.full.fill", tint: .init(0.600, 0.05, 0.62))
    guard let subject = subject?.lowercased(), !subject.isEmpty else {
        return catchAll
    }
    let map: [(String, SubjectStyle)] = [
        ("sonstige", catchAll),
        // compounds first — each of these contains a keyword further down
        ("wirtschaft", .init(symbol: "chart.line.uptrend.xyaxis", tint: .init(0.112, 0.95, 0.90))),
        ("mint", .init(symbol: "gearshape.2.fill", tint: .init(0.410, 0.88, 0.84))),
        ("förderband", .init(symbol: "sparkles", tint: .init(0.205, 0.90, 0.88))),
        ("forderband", .init(symbol: "sparkles", tint: .init(0.205, 0.90, 0.88))),
        ("hospitation", .init(symbol: "eye.fill", tint: .init(0.585, 0.45, 0.50))),
        ("mathe", .init(symbol: "x.squareroot", tint: .init(0.618, 0.90, 0.96))),
        ("math", .init(symbol: "x.squareroot", tint: .init(0.618, 0.90, 0.96))),
        ("physik", .init(symbol: "atom", tint: .init(0.710, 0.80, 0.90))),
        ("chemie", .init(symbol: "testtube.2", tint: .init(0.805, 0.82, 0.82))),
        ("bio", .init(symbol: "leaf.fill", tint: .init(0.365, 0.95, 0.64))),
        ("informatik", .init(symbol: "desktopcomputer", tint: .init(0.510, 0.90, 0.88))),
        ("deutsch", .init(symbol: "text.book.closed.fill", tint: .init(0.995, 0.84, 0.94))),
        ("englisch", .init(symbol: "character.book.closed.fill", tint: .init(0.072, 0.92, 0.97))),
        ("franz", .init(symbol: "character.book.closed.fill", tint: .init(0.870, 0.72, 0.90))),
        ("latein", .init(symbol: "building.columns.fill", tint: .init(0.038, 0.80, 0.78))),
        ("spanisch", .init(symbol: "character.book.closed.fill", tint: .init(0.148, 0.95, 0.94))),
        ("geschichte", .init(symbol: "hourglass", tint: .init(0.088, 0.70, 0.58))),
        ("erdkunde", .init(symbol: "globe.europe.africa.fill", tint: .init(0.462, 0.88, 0.72))),
        ("geo", .init(symbol: "globe.europe.africa.fill", tint: .init(0.462, 0.88, 0.72))),
        ("musik", .init(symbol: "music.note", tint: .init(0.755, 0.42, 0.99))),
        ("kunst", .init(symbol: "paintpalette.fill", tint: .init(0.935, 0.62, 0.98))),
        ("sport", .init(symbol: "figure.run", tint: .init(0.300, 0.68, 0.96))),
        ("religion", .init(symbol: "book.closed.fill", tint: .init(0.665, 0.55, 0.84))),
        ("ethik", .init(symbol: "person.2.fill", tint: .init(0.545, 0.62, 0.72))),
        ("politik", .init(symbol: "building.columns.fill", tint: .init(0.115, 0.92, 0.66))),
    ]
    for (keyword, style) in map where subject.contains(keyword) {
        return style
    }
    return fallback
}

extension View {
    /// The answer a subject with nothing in it gives when it is tapped.
    ///
    /// Both grids draw every subject of the school year, the empty ones
    /// included — a subject you have not recorded yet is still a subject, and
    /// hiding it would make the grid a different shape every week. Opening one
    /// would land on a blank screen, and `.disabled()` would dim it and then say
    /// nothing at all, which is the wrong answer when the tile looks exactly
    /// like the fifteen beside it. So it says what is missing, out loud.
    func emptySubjectNotice(
        _ subject: Binding<String?>,
        detail: @escaping (String) -> String
    ) -> some View {
        alert(
            "Noch keine Aufnahmen",
            isPresented: Binding(
                get: { subject.wrappedValue != nil },
                set: { if !$0 { subject.wrappedValue = nil } }
            ),
            presenting: subject.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { name in
            Text(detail(name))
        }
        .sensoryFeedback(.warning, trigger: subject.wrappedValue)
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
