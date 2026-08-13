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

/// Icon and folder colour for a school subject.
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
func subjectStyle(for subject: String?) -> SubjectStyle {
    // A subject nobody wrote a rule for.
    let fallback = SubjectStyle(icon: "ph.graduation-cap", color: .blue)
    let catchAll = SubjectStyle(icon: "ph.tray", color: .gray)
    guard let subject = subject?.lowercased(), !subject.isEmpty else {
        return catchAll
    }
    let map: [(String, SubjectStyle)] = [
        ("sonstige", catchAll),
        // compounds first — each of these contains a keyword further down
        ("wirtschaft", .init(
            icon: "ph.chart-line-up", color: .subjectAmber
        )),
        ("mint", .init(icon: "ph.gear", color: .cyan)),
        ("förderband", .init(icon: "ph.sparkle", color: .yellow)),
        ("forderband", .init(icon: "ph.sparkle", color: .yellow)),
        ("hospitation", .init(icon: "ph.eye", color: .subjectSteel)),
        ("mathe", .init(icon: "ph.math-operations", color: .blue)),
        ("math", .init(icon: "ph.math-operations", color: .blue)),
        ("physik", .init(icon: "ph.atom", color: .indigo)),
        ("chemie", .init(icon: "ph.flask", color: .purple)),
        ("bio", .init(icon: "ph.plant", color: .green)),
        ("informatik", .init(
            icon: "ph.code", color: .subjectSteel
        )),
        ("deutsch", .init(
            icon: "ph.book-open-text", color: .red
        )),
        ("englisch", .init(
            icon: "ph.translate", color: .orange
        )),
        ("franz", .init(
            icon: "ph.chat-teardrop-text", color: .subjectPlum
        )),
        ("latein", .init(
            icon: "ph.scroll", color: .subjectTerracotta
        )),
        ("spanisch", .init(
            icon: "ph.chats-circle", color: .yellow
        )),
        ("geschichte", .init(icon: "ph.hourglass", color: .brown)),
        ("erdkunde", .init(
            icon: "ph.globe-stand", color: .teal
        )),
        ("geo", .init(
            icon: "ph.globe-stand", color: .teal
        )),
        ("musik", .init(icon: "ph.music-notes", color: .subjectPlum)),
        ("kunst", .init(icon: "ph.palette", color: .pink)),
        ("sport", .init(icon: "ph.person-simple-run", color: .mint)),
        ("religion", .init(icon: "ph.church", color: .indigo)),
        ("ethik", .init(icon: "ph.scales", color: .subjectSteel)),
        ("politik", .init(
            icon: "ph.bank", color: .subjectAmber
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
    /// The grid draws every subject of the school year, the empty ones included
    /// — a subject you have not recorded yet is still a subject, and
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
/// and offering to try again when the server has already refused the request is
/// worse than wrong, because the answer will be the same every single time.
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
