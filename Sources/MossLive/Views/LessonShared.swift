import Foundation
import SwiftUI

/// The four folder colours the system palette has no entry for. Same character
/// as the system ones — saturated, mid-brightness — so a folder built from one
/// sits beside a folder built from `.blue` without looking imported.
private extension Color {
    static let subjectTerracotta = Color(hue: 0.045, saturation: 0.60, brightness: 0.82)
    static let subjectAmber = Color(hue: 0.108, saturation: 0.82, brightness: 0.86)
    static let subjectSteel = Color(hue: 0.575, saturation: 0.32, brightness: 0.62)
    static let subjectPlum = Color(hue: 0.885, saturation: 0.48, brightness: 0.68)
}

/// A subject's card colour, kept as the numbers it was chosen as.
///
/// Not a `Color`. A card is filled edge to edge with this and then written on in
/// white, so the screen needs to know how bright it actually is — and the only
/// way back out of a `Color` is `UIColor(color).getHue(...)`, which resolves
/// against whatever trait collection happens to be current. Keeping the three
/// numbers makes it arithmetic instead of a round trip.
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

    /// How much black the card needs behind its type, at the foot and at the
    /// head, for white to stay readable.
    ///
    /// Nought across most of the wheel — a saturated blue or a purple is already
    /// dark enough to write white on, and those cards are drawn as flat colour
    /// and nothing else. It is the yellows and the greens that need help: white
    /// on Spanisch is 1.2:1. They get it only where the type is, so the middle
    /// of every card is the colour itself at full strength either way.
    ///
    /// This replaces a gradient that darkened the whole lower half of every
    /// card to a fixed ceiling. That was legible and it was dead — it spent the
    /// colour of twenty-four subjects to fix the six that needed fixing.
    func scrim(contrast: ColorSchemeContrast = .standard) -> (top: Double, bottom: Double) {
        let target = contrast == .increased ? 4.5 : 3.1
        var alpha = 0.0
        while alpha < 0.55 {
            if Self.contrastWithWhite(hue: hue, saturation: saturation, brightness: brightness, over: alpha)
                >= target {
                break
            }
            alpha += 0.05
        }
        // The glyph is a thick stroke and forgives what 13pt type does not, so
        // the head of the card is shaded about half as hard as the foot.
        return (top: alpha * 0.45, bottom: alpha)
    }

    /// White against this colour with `over` of black composited on top of it.
    /// Black over a colour is the colour scaled, which is why this is a
    /// multiply rather than a blend.
    private static func contrastWithWhite(
        hue: Double,
        saturation: Double,
        brightness: Double,
        over alpha: Double
    ) -> Double {
        let (red, green, blue) = rgb(hue: hue, saturation: saturation, brightness: brightness)
        let scale = 1 - alpha
        func channel(_ value: Double) -> Double {
            let scaled = value * scale
            return scaled <= 0.03928 ? scaled / 12.92 : pow((scaled + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        return 1.05 / (luminance + 0.05)
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

/// SF Symbol, folder colour and card colour for a school subject.
struct SubjectStyle {
    let symbol: String
    /// What the Stunden folder is washed with. The system palette, as that grid
    /// has always drawn it.
    let color: Color
    /// What a Lernen card is filled with. A separate, brighter set: a folder
    /// tints a pale shape behind black text, a card *is* the colour, and one
    /// value cannot be right for both.
    let tint: SubjectTint

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

/// The catch-all folder: everything recorded while no lesson was running — the
/// holidays, an evening, a free period.
let otherSubjectName = "Sonstige"

/// Best-effort keyword match from a subject name to its icon and colours.
///
/// Matched against the name the backend labels a recording with, which is
/// WebUntis' long name where it has one (`Mathematik`, `Wirtschaft/Politik`,
/// `MINT - Mittelstufe`) and the short code where it does not. Keywords are
/// tried in order, so a compound name lands on the more specific entry:
/// `Wirtschaft/Politik` is its own subject rather than either half.
///
/// Two colours per subject, because they do two different jobs. `color` is the
/// system palette the Stunden folders have always used, washed out to a pastel
/// behind black text. `tint` fills a Lernen card edge to edge and gets written
/// on in white, so it has to be both brighter and further from its neighbours —
/// the system set has thirteen distinct entries and the timetable needs
/// twenty-two, which left Informatik, Ethik and Hospitation sharing one
/// grey-blue and Musik sharing a plum with Französisch.
///
/// The card colours were placed by measurement: no two are closer than 27 units
/// of CIE76, roughly where two tiles stop being the same tile, and they average
/// 0.90 brightness at 0.79 saturation.
func subjectStyle(for subject: String?) -> SubjectStyle {
    // A subject nobody wrote a rule for: a blue with the life turned down, so it
    // reads as "not one of the known ones" rather than as Mathematik.
    let fallback = SubjectStyle(
        symbol: "graduationcap.fill", color: .blue, tint: .init(0.630, 0.30, 0.90)
    )
    let catchAll = SubjectStyle(
        symbol: "tray.full.fill", color: .gray, tint: .init(0.600, 0.05, 0.64)
    )
    guard let subject = subject?.lowercased(), !subject.isEmpty else {
        return catchAll
    }
    let map: [(String, SubjectStyle)] = [
        ("sonstige", catchAll),
        // compounds first — each of these contains a keyword further down
        ("wirtschaft", .init(
            symbol: "chart.line.uptrend.xyaxis", color: .subjectAmber, tint: .init(0.125, 0.95, 0.92)
        )),
        ("mint", .init(symbol: "gearshape.2.fill", color: .cyan, tint: .init(0.431, 0.87, 0.93))),
        ("förderband", .init(symbol: "sparkles", color: .yellow, tint: .init(0.206, 0.89, 0.99))),
        ("forderband", .init(symbol: "sparkles", color: .yellow, tint: .init(0.206, 0.89, 0.99))),
        ("hospitation", .init(symbol: "eye.fill", color: .subjectSteel, tint: .init(0.608, 0.62, 0.82))),
        ("mathe", .init(symbol: "x.squareroot", color: .blue, tint: .init(0.623, 0.96, 0.86))),
        ("math", .init(symbol: "x.squareroot", color: .blue, tint: .init(0.623, 0.96, 0.86))),
        ("physik", .init(symbol: "atom", color: .indigo, tint: .init(0.697, 0.87, 0.96))),
        ("chemie", .init(symbol: "testtube.2", color: .purple, tint: .init(0.805, 0.85, 0.88))),
        ("bio", .init(symbol: "leaf.fill", color: .green, tint: .init(0.375, 0.95, 0.80))),
        ("informatik", .init(
            symbol: "desktopcomputer", color: .subjectSteel, tint: .init(0.512, 0.95, 0.89)
        )),
        ("deutsch", .init(
            symbol: "text.book.closed.fill", color: .red, tint: .init(0.973, 0.87, 0.95)
        )),
        ("englisch", .init(
            symbol: "character.book.closed.fill", color: .orange, tint: .init(0.077, 0.98, 0.99)
        )),
        ("franz", .init(
            symbol: "character.book.closed.fill", color: .subjectPlum, tint: .init(0.872, 0.78, 0.92)
        )),
        ("latein", .init(
            symbol: "building.columns.fill", color: .subjectTerracotta, tint: .init(0.032, 0.98, 0.97)
        )),
        ("spanisch", .init(
            symbol: "character.book.closed.fill", color: .yellow, tint: .init(0.157, 0.98, 0.98)
        )),
        ("geschichte", .init(symbol: "hourglass", color: .brown, tint: .init(0.088, 0.80, 0.80))),
        ("erdkunde", .init(
            symbol: "globe.europe.africa.fill", color: .teal, tint: .init(0.467, 0.88, 0.80)
        )),
        ("geo", .init(
            symbol: "globe.europe.africa.fill", color: .teal, tint: .init(0.467, 0.88, 0.80)
        )),
        ("musik", .init(symbol: "music.note", color: .subjectPlum, tint: .init(0.762, 0.55, 0.98))),
        ("kunst", .init(symbol: "paintpalette.fill", color: .pink, tint: .init(0.938, 0.68, 0.98))),
        ("sport", .init(symbol: "figure.run", color: .mint, tint: .init(0.272, 0.88, 0.99))),
        ("religion", .init(symbol: "book.closed.fill", color: .indigo, tint: .init(0.641, 0.62, 0.99))),
        ("ethik", .init(symbol: "person.2.fill", color: .subjectSteel, tint: .init(0.540, 0.94, 0.80))),
        ("politik", .init(
            symbol: "building.columns.fill", color: .subjectAmber, tint: .init(0.190, 0.71, 0.80)
        )),
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
