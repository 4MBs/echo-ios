import AppIntents
import SwiftUI
import WidgetKit

/// Stealth answer widget: tap anywhere on it → the Fedora backend answers the
/// last 30 seconds of the running recording session → the answer appears in
/// the widget itself. No app opening, works on the Home Screen and the Lock
/// Screen (without unlocking).
///
/// Zero configuration: the widget reads the app's server settings through the
/// App Group (see SharedConfig, which resolves the group ID the sideloading
/// tool actually granted at runtime). Per-widget Edit Widget parameters
/// override the shared settings and are the fallback if the signer stripped
/// app groups entirely.
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
    /// Runs from the Lock Screen without unlocking the device — the whole
    /// point is answering with the iPad face-down on the desk.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun = false

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
            let conn = Self.resolveConnection(
                host: host, port: port, token: token, contextSeconds: contextSeconds
            )
            let text = try await WidgetBackend.requestAnswer(
                host: conn.host, port: conn.port, token: conn.token,
                contextSeconds: conn.contextSeconds
            )
            AnswerSnapshotStore.save(.init(state: .answer, text: text, updatedAt: Date()))
        } catch {
            let message = (error as? WidgetBackendError)?.message ?? error.localizedDescription
            AnswerSnapshotStore.save(.init(state: .failure, text: message, updatedAt: Date()))
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }

    /// Per-widget parameters win when set; otherwise the app's own settings
    /// (shared through the App Group) apply — zero configuration needed.
    static func resolveConnection(
        host: String, port: Int, token: String, contextSeconds: Int
    ) -> SharedConfig.Connection {
        if !host.trimmingCharacters(in: .whitespaces).isEmpty && !token.isEmpty {
            return .init(host: host, port: port, token: token, contextSeconds: contextSeconds)
        }
        var shared = SharedConfig.read()
        if contextSeconds > 0, contextSeconds != 30 {
            shared.contextSeconds = contextSeconds
        }
        return shared
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
            // distinguish "sharing broken" from "app never configured" so the
            // tile tells the truth about what to fix
            if SharedConfig.resolvedGroupID == nil {
                throw WidgetBackendError(
                    message: "App-widget link unavailable (SideStore stripped app groups). "
                        + "Long-press → Edit Widget → enter server & token there."
                )
            }
            throw WidgetBackendError(
                message: "Not configured. Open the MOSS Live app once and enter server & token in Settings."
            )
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            // network failures must never masquerade as configuration problems
            let reason = switch error.code {
            case .timedOut: "Server not answering: is run.sh running on the computer?"
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                "Can't reach the server: is Tailscale connected on this device?"
            default: "Network error: \(error.localizedDescription)"
            }
            throw WidgetBackendError(message: reason)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Payload: Decodable {
            let ok: Bool
            let text: String
            let error: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            if status == 401 {
                throw WidgetBackendError(message: "The server rejected the auth token.")
            }
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
    /// Whether a usable server connection exists (widget params or the app's
    /// shared settings) — drives the unconfigured hint in the idle state.
    var configured: Bool = true
}

struct AnswerProvider: AppIntentTimelineProvider {
    /// Answers auto-expire back to the blank tile (stealth: nothing lingers
    /// on the Home/Lock Screen after class).
    static let answerLifetime: TimeInterval = 10 * 60

    func placeholder(in context: Context) -> AnswerEntry {
        AnswerEntry(
            date: .now,
            snapshot: .init(state: .answer, text: "Paris.", updatedAt: .now),
            config: WidgetConfigIntent()
        )
    }

    func snapshot(for configuration: WidgetConfigIntent, in context: Context) async -> AnswerEntry {
        // the widget gallery must show the demo answer, never a stale
        // failure snapshot from a previous tap
        if context.isPreview {
            return placeholder(in: context)
        }
        return AnswerEntry(
            date: .now,
            snapshot: currentSnapshot(),
            config: configuration,
            configured: isConfigured(configuration)
        )
    }

    func timeline(for configuration: WidgetConfigIntent, in context: Context) async -> Timeline<AnswerEntry> {
        let snapshot = currentSnapshot()
        let entry = AnswerEntry(
            date: .now,
            snapshot: snapshot,
            config: configuration,
            configured: isConfigured(configuration)
        )
        switch snapshot.state {
        case .answer, .failure:
            // schedule the wipe back to the blank tile
            let expiry = snapshot.updatedAt.addingTimeInterval(Self.answerLifetime)
            let blank = AnswerEntry(
                date: max(expiry, .now + 1),
                snapshot: .init(state: .idle, text: "", updatedAt: .now),
                config: configuration,
                configured: isConfigured(configuration)
            )
            return Timeline(entries: [entry, blank], policy: .never)
        case .idle, .loading:
            return Timeline(entries: [entry], policy: .never)
        }
    }

    private func isConfigured(_ configuration: WidgetConfigIntent) -> Bool {
        FetchAnswerIntent.resolveConnection(
            host: configuration.host,
            port: configuration.port,
            token: configuration.token,
            contextSeconds: configuration.contextSeconds
        ).isUsable
    }

    private func currentSnapshot() -> AnswerSnapshot {
        let snapshot = AnswerSnapshotStore.load()
        if snapshot.state == .answer || snapshot.state == .failure,
           Date().timeIntervalSince(snapshot.updatedAt) > Self.answerLifetime {
            return AnswerSnapshot(state: .idle, text: "", updatedAt: .distantPast)
        }
        return snapshot
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
        .description("Tap to answer the last seconds of the lecture. The answer appears right here.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
            .accessoryRectangular, .accessoryInline,
        ])
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
        // The system dims/shimmers this content the instant a tap lands, so
        // the user gets feedback even before the network round-trip finishes.
        .invalidatableContent()
        .containerBackground(for: .widget) {
            if family.isAccessory {
                Color.clear
            } else {
                Color(red: 0.05, green: 0.05, blue: 0.06)
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
        case .idle: entry.configured ? "·" : "⚙"
        case .loading: "…"
        case .answer: entry.snapshot.text
        case .failure: "!"
        }
    }

    @ViewBuilder
    private var fullContent: some View {
        switch entry.snapshot.state {
        case .idle:
            if entry.configured {
                // near-invisible tap target
                Circle()
                    .fill(.white.opacity(family.isAccessory ? 0.35 : 0.10))
                    .frame(width: 5, height: 5)
            } else {
                // no usable server settings anywhere: point at the app once
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(family.isAccessory ? .secondary : Color.white.opacity(0.3))
            }
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
        case .systemMedium: .footnote
        case .systemLarge: .body
        default: .title3
        }
    }
}

extension WidgetFamily {
    var isAccessory: Bool {
        self == .accessoryRectangular || self == .accessoryInline || self == .accessoryCircular
    }
}
