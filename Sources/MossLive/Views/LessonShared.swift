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

/// A subject's card colour, as the hex it was taken from.
///
/// Hex, because these are lifted from published palettes rather than derived —
/// the last set was computed by an optimiser balancing separation against
/// contrast, and it produced exactly the muted wheel that gets described as
/// matt. A card colour should be a value somebody already decided looks good.
///
/// Kept as components rather than as a `Color` because the card is filled edge
/// to edge with this and then written on in white, so the screen has to know how
/// bright it actually is. The only way back out of a `Color` is
/// `UIColor(color).getHue(...)`, which resolves against whatever trait
/// collection happens to be current.
struct SubjectTint {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// How much black the card needs behind its type, at the foot and at the
    /// head, for white to stay readable.
    ///
    /// Nought across most of the wheel — a saturated blue or a red is already
    /// dark enough to write white on, and those cards are drawn as flat colour
    /// and nothing else. It is the yellows and the light greens that need help:
    /// white on a vivid yellow is about 1.2:1. They get it only where the type
    /// is, so the middle of every card is the colour itself at full strength
    /// either way.
    ///
    /// This replaces a gradient that darkened the whole lower half of every card
    /// to a fixed ceiling. That was legible and it was dead: it spent the colour
    /// of twenty-four subjects to fix the handful that needed fixing.
    func scrim(contrast: ColorSchemeContrast = .standard) -> (top: Double, bottom: Double) {
        let target = contrast == .increased ? 4.5 : 3.1
        var alpha = 0.0
        while alpha < 0.55, contrastWithWhite(over: alpha) < target {
            alpha += 0.05
        }
        // The glyph is a thick stroke and forgives what 13pt type does not, so
        // the head of the card is shaded about half as hard as the foot.
        return (top: alpha * 0.45, bottom: alpha)
    }

    /// White against this colour with `alpha` of black composited over it.
    /// Black over a colour is the colour scaled, so this is a multiply.
    private func contrastWithWhite(over alpha: Double) -> Double {
        let scale = 1 - alpha
        func channel(_ value: Double) -> Double {
            let scaled = value * scale
            return scaled <= 0.03928 ? scaled / 12.92 : pow((scaled + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        return 1.05 / (luminance + 0.05)
    }
}

/// Icon, folder colour and card colour for a school subject.
struct SubjectStyle {
    /// The name of an image set in `Assets.xcassets/Subjects`, drawn from
    /// Phosphor's bold weight.
    ///
    /// Not an SF Symbol any more. Apple's set covers most of a timetable well,
    /// but it has no justice scales for Ethik and no church for Religion, and
    /// several of the near-misses it does have read as a smudge at 26pt in
    /// white — `testtube.2` for Chemie being the one that got noticed. Phosphor
    /// has all of them, drawn on one grid, and its bold weight is a stroke
    /// heavy enough to survive white-on-saturated instead of blooming away.
    let icon: String
    /// What the Stunden folder is washed with. The system palette, as that grid
    /// has always drawn it.
    let color: Color
    /// What a Lernen card is filled with. A separate, brighter set: a folder
    /// tints a pale shape behind black text, a card *is* the colour, and one
    /// value cannot be right for both.
    let tint: SubjectTint
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
/// on in white.
///
/// **Where the card colours come from.** German schools do colour-code subjects
/// — it is the Heftumschlag and Schnellhefter convention, the one on the
/// Materialliste that comes home in September — and for the core it is
/// consistent enough to be worth honouring: **Deutsch rot, Mathematik blau,
/// Sachkunde/Biologie grün, Englisch gelb**, with Geschichte orange and Erdkunde
/// braun recurring independently across schools. It is not codified anywhere
/// (no KMK ruling, no stationer publishes a chart) and beyond those it collapses
/// — every secondary school issues its own list, and WebUntis ships no default
/// palette at all. So the convention is followed where it exists and the rest
/// are placed for separation.
///
/// The values are **Material Design A400/A700**, taken as published rather than
/// computed. Three palettes preceded this one, each derived by an optimiser
/// trading saturation away for contrast, and each landed somewhere between muted
/// and matt. Legibility is not the fill's job here — that is what the scrim is
/// for — so the fill can simply be the most saturated published value that fits.
/// They average 0.89 saturation at 0.88 value, and no two are closer than 12
/// units of CIE76.
///
/// Erdkunde is the one place the convention is bent: *braun* has no vibrant
/// value anywhere in Material, so it gets Deep Orange A700 — a burnt earth
/// rather than a mud. Latein has no convention at all and takes Purpur.
func subjectStyle(for subject: String?) -> SubjectStyle {
    // A subject nobody wrote a rule for. Not a blue: blue is Mathematik, and an
    // unrecognised subject should not arrive looking like the timetable's most
    // recognisable one.
    let fallback = SubjectStyle(
        icon: "ph.graduation-cap", color: .blue, tint: .init(0x00B8D4)
    )
    let catchAll = SubjectStyle(
        icon: "ph.tray", color: .gray, tint: .init(0x546E7A)
    )
    guard let subject = subject?.lowercased(), !subject.isEmpty else {
        return catchAll
    }
    let map: [(String, SubjectStyle)] = [
        ("sonstige", catchAll),
        // compounds first — each of these contains a keyword further down
        ("wirtschaft", .init(
            icon: "ph.chart-line-up", color: .subjectAmber, tint: .init(0x00BFA5)
        )),
        ("mint", .init(icon: "ph.gear", color: .cyan, tint: .init(0x76FF03))),
        ("förderband", .init(icon: "ph.sparkle", color: .yellow, tint: .init(0xAEEA00))),
        ("forderband", .init(icon: "ph.sparkle", color: .yellow, tint: .init(0xAEEA00))),
        ("hospitation", .init(icon: "ph.eye", color: .subjectSteel, tint: .init(0x6D4C41))),
        ("mathe", .init(icon: "ph.math-operations", color: .blue, tint: .init(0x2979FF))),
        ("math", .init(icon: "ph.math-operations", color: .blue, tint: .init(0x2979FF))),
        ("physik", .init(icon: "ph.atom", color: .indigo, tint: .init(0x673AB7))),
        ("chemie", .init(icon: "ph.flask", color: .purple, tint: .init(0xF50057))),
        ("bio", .init(icon: "ph.plant", color: .green, tint: .init(0x64DD17))),
        ("informatik", .init(
            icon: "ph.code", color: .subjectSteel, tint: .init(0x1DE9B6)
        )),
        ("deutsch", .init(
            icon: "ph.book-open-text", color: .red, tint: .init(0xFF1744)
        )),
        ("englisch", .init(
            icon: "ph.translate", color: .orange, tint: .init(0xFFD600)
        )),
        ("franz", .init(
            icon: "ph.chat-teardrop-text", color: .subjectPlum, tint: .init(0xFFAB00)
        )),
        ("latein", .init(
            icon: "ph.scroll", color: .subjectTerracotta, tint: .init(0xAA00FF)
        )),
        ("spanisch", .init(
            icon: "ph.chats-circle", color: .yellow, tint: .init(0xFF3D00)
        )),
        ("geschichte", .init(icon: "ph.hourglass", color: .brown, tint: .init(0xFF6D00))),
        ("erdkunde", .init(
            icon: "ph.globe-stand", color: .teal, tint: .init(0xDD2C00)
        )),
        ("geo", .init(
            icon: "ph.globe-stand", color: .teal, tint: .init(0xDD2C00)
        )),
        ("musik", .init(icon: "ph.music-notes", color: .subjectPlum, tint: .init(0x6200EA))),
        ("kunst", .init(icon: "ph.palette", color: .pink, tint: .init(0xD500F9))),
        ("sport", .init(icon: "ph.person-simple-run", color: .mint, tint: .init(0x00C853))),
        ("religion", .init(icon: "ph.church", color: .indigo, tint: .init(0x3F51B5))),
        ("ethik", .init(icon: "ph.scales", color: .subjectSteel, tint: .init(0x304FFE))),
        ("politik", .init(
            icon: "ph.bank", color: .subjectAmber, tint: .init(0x0091EA)
        )),
    ]
    for (keyword, style) in map where subject.contains(keyword) {
        return style
    }
    return fallback
}

// MARK: - How solid something is

/// How well a card is known, as a word.
///
/// The area used to print this as a percentage — "72 % bereit" — computed from
/// `log2(stability + 2) / 6` minus a lapse deduction. Two decimal places of
/// nothing: the student cannot derive it, cannot influence it directly and
/// cannot tell 72 from 68. A word can be checked against how the last round
/// actually felt, and it is never the only carrier of the meaning: every place
/// that shows it shows a bar as well.
enum Readiness: Equatable {
    case fresh
    case shaky
    case nearly
    case solid

    init(_ value: Double) {
        switch value {
        case ..<0.01: self = .fresh
        case ..<0.45: self = .shaky
        case ..<0.75: self = .nearly
        default: self = .solid
        }
    }

    var word: String {
        switch self {
        case .fresh: "neu"
        case .shaky: "wackelt"
        case .nearly: "fast sicher"
        case .solid: "sicher"
        }
    }
}

/// How solid one card is, 0…1.
///
/// **Provisional.** The server sends a readiness per exam but not per subject or
/// topic, so this stands in for those two — which is why it is never printed as
/// a number. One implementation, here, because there were two of it with
/// different bracketing.
func cardReadiness(_ card: BackendAPI.LearnCard) -> Double {
    guard (card.reps ?? 0) > 0 else { return 0 }
    let stability = max(0, card.stability ?? Double(card.box))
    let strength = min(1, log2(stability + 2) / 6)
    let lapsePenalty = min(0.25, Double(card.lapses ?? 0) * 0.03)
    return max(0, strength - lapsePenalty)
}

/// A group of cards about one thing, and how solid it is.
struct StudyTopic: Identifiable, Equatable {
    let name: String
    let subject: String?
    let cards: [BackendAPI.LearnCard]
    let readiness: Double

    var id: String { "\(subject ?? "")|\(name)" }
    var word: String { Readiness(readiness).word }
}

/// The deck grouped by what it is about, weakest first.
///
/// The concept the card generator wrote, falling back to the lesson it came
/// from — one grouping for the whole app, where there were two with slightly
/// different fallbacks.
func studyTopics(_ cards: [BackendAPI.LearnCard]) -> [StudyTopic] {
    Dictionary(grouping: cards) { card in
        card.concept?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
            ?? card.lessonTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
            ?? "Allgemein"
    }
    .map { name, group in
        let values = group.map(cardReadiness)
        return StudyTopic(
            name: name,
            subject: group.first?.subject,
            cards: group,
            readiness: values.reduce(0, +) / Double(max(1, values.count))
        )
    }
    .sorted { lhs, rhs in
        lhs.readiness == rhs.readiness
            ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            : lhs.readiness < rhs.readiness
    }
}

extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
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

// MARK: - What a failed request looks like

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
