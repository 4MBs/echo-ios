import AppIntents
import SwiftUI
import WidgetKit

/// Stealth answer widget: tap anywhere on it → the Fedora backend answers the
/// last 30 seconds of the running recording session → the answer appears in
/// the widget itself. No app opening, works on the Home Screen and the Lock
/// Screen.
///
/// Configuration (server address / token) lives on the widget itself
/// (long-press → Edit Widget) rather than in shared app storage, because
/// SideStore re-signs apps with rewritten app-group entitlements, which would
/// silently break cross-process sharing.
@main
struct MossLiveWidgetBundle: WidgetBundle {
    var body: some Widget {
        AnswerWidget()
    }
}

// MARK: - Configuration (long-press -> Edit Widget)

struct WidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "MOSS Live Answer"
    static var description = IntentDescription("Configure the connection to your Fedora server.")

    @Parameter(title: "Server address", default: "")
    var host: String

    @Parameter(title: "Port", default: 8787)
    var port: Int

    @Parameter(title: "Auth token", default: "")
    var token: String

    @Parameter(title: "Context seconds", default: 30)
    var contextSeconds: Int
}

// MARK: - The tap action

struct FetchAnswerIntent: AppIntent {
    static var title: LocalizedStringResource = "Answer Last Seconds"
    static var description = IntentDescription("Asks the AI about the last seconds of the lecture.")

    @Parameter(title: "Server address", default: "")
    var host: String

    @Parameter(title: "Port", default: 8787)
    var port: Int

    @Parameter(title: "Auth token", default: "")
    var token: String

    @Parameter(title: "Context seconds", default: 30)
    var contextSeconds: Int

    init() {}

    init(host: String, port: Int, token: String, contextSeconds: Int) {
        self.host = host
        self.port = port
        self.token = token
        self.contextSeconds = contextSeconds
    }

    func perform() async throws -> some IntentResult {
        AnswerSnapshotStore.save(.init(state: .loading, text: "", updatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
        do {
            let text = try await WidgetBackend.requestAnswer(
                host: host, port: port, token: token, contextSeconds: contextSeconds
            )
            AnswerSnapshotStore.save(.init(state: .answer, text: text, updatedAt: Date()))
        } catch {
            let message = (error as? WidgetBackendError)?.message ?? error.localizedDescription
            AnswerSnapshotStore.save(.init(state: .failure, text: message, updatedAt: Date()))
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Backend call (plain HTTP over Tailscale)

struct WidgetBackendError: Error {
    let message: String
}

enum WidgetBackend {
    static func requestAnswer(host: String, port: Int, token: String, contextSeconds: Int) async throws -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        guard !cleanHost.isEmpty, !token.isEmpty else {
            throw WidgetBackendError(message: "Long-press the widget → Edit Widget → enter server & token.")
        }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = cleanHost
        comps.port = port
        comps.path = "/answer"
        guard let url = comps.url else {
            throw WidgetBackendError(message: "Invalid server address.")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context_seconds": contextSeconds])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Payload: Decodable {
            let ok: Bool
            let text: String
            let error: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw WidgetBackendError(message: "Server error (HTTP \(status)).")
        }
        guard payload.ok else {
            throw WidgetBackendError(message: payload.error)
        }
        return payload.text
    }
}

// MARK: - Snapshot persistence (widget-process local)

struct AnswerSnapshot: Codable {
    enum State: String, Codable {
        case idle, loading, answer, failure
    }

    var state: State
    var text: String
    var updatedAt: Date
}

enum AnswerSnapshotStore {
    private static let key = "answer-snapshot"

    static func save(_ snapshot: AnswerSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> AnswerSnapshot {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(AnswerSnapshot.self, from: data)
        else {
            return AnswerSnapshot(state: .idle, text: "", updatedAt: .distantPast)
        }
        return snapshot
    }
}

// MARK: - Timeline

struct AnswerEntry: TimelineEntry {
    let date: Date
    let snapshot: AnswerSnapshot
    let config: WidgetConfigIntent
}

struct AnswerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AnswerEntry {
        AnswerEntry(
            date: .now,
            snapshot: .init(state: .answer, text: "Paris.", updatedAt: .now),
            config: WidgetConfigIntent()
        )
    }

    func snapshot(for configuration: WidgetConfigIntent, in context: Context) async -> AnswerEntry {
        AnswerEntry(date: .now, snapshot: AnswerSnapshotStore.load(), config: configuration)
    }

    func timeline(for configuration: WidgetConfigIntent, in context: Context) async -> Timeline<AnswerEntry> {
        let entry = AnswerEntry(date: .now, snapshot: AnswerSnapshotStore.load(), config: configuration)
        return Timeline(entries: [entry], policy: .never)
    }
}

// MARK: - Widget

struct AnswerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "MossLiveAnswerWidget",
            intent: WidgetConfigIntent.self,
            provider: AnswerProvider()
        ) { entry in
            AnswerWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Answer")
        .description("Tap to answer the last seconds of the lecture — the answer appears right here.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

/// Deliberately stealth: no branding, no labels — an empty dark tile with a
/// barely visible dot. Tap it and only the answer text appears, scaled to fit
/// the widget. Errors show as small dim text (needed for setup/debugging).
struct AnswerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AnswerEntry

    private var intent: FetchAnswerIntent {
        FetchAnswerIntent(
            host: entry.config.host,
            port: entry.config.port,
            token: entry.config.token,
            contextSeconds: entry.config.contextSeconds
        )
    }

    var body: some View {
        Button(intent: intent) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            if family == .systemSmall || family == .systemMedium {
                Color(red: 0.05, green: 0.05, blue: 0.06)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if family == .accessoryInline {
            // inline renders exactly one line of text
            Text(inlineText)
        } else {
            fullContent
        }
    }

    private var inlineText: String {
        switch entry.snapshot.state {
        case .idle: "·"
        case .loading: "…"
        case .answer: entry.snapshot.text
        case .failure: "!"
        }
    }

    @ViewBuilder
    private var fullContent: some View {
        switch entry.snapshot.state {
        case .idle:
            // near-invisible tap target
            Circle()
                .fill(.white.opacity(family.isAccessory ? 0.35 : 0.10))
                .frame(width: 5, height: 5)
        case .loading:
            HStack(spacing: 3) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    Circle()
                        .fill(.white.opacity(family.isAccessory ? 0.6 : 0.25))
                        .frame(width: 4, height: 4)
                }
            }
        case .answer:
            Text(entry.snapshot.text)
                .font(answerFont)
                .minimumScaleFactor(0.4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(family.isAccessory ? .primary : Color.white.opacity(0.9))
        case .failure:
            Text(entry.snapshot.text)
                .font(.system(size: 10))
                .minimumScaleFactor(0.6)
                .foregroundStyle(family.isAccessory ? .secondary : Color.white.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }

    private var answerFont: Font {
        switch family {
        case .accessoryInline: .body
        case .accessoryRectangular: .caption2
        case .systemSmall: .caption2
        default: .footnote
        }
    }
}

extension WidgetFamily {
    var isAccessory: Bool {
        self == .accessoryRectangular || self == .accessoryInline || self == .accessoryCircular
    }
}
