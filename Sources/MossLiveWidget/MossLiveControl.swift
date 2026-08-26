import AppIntents
import SwiftUI
import WidgetKit

let answerWidgetKind = "MossLiveAnswerWidget"
let answerControlKind = "com.fourmbs.mosslive.answer-control"

/// Control Center uses its own configuration-intent protocol, but exposes the
/// same escape hatch as the widget for sideloaded builds whose signer removed
/// the App Group entitlement.
struct ControlConfigIntent: ControlConfigurationIntent {
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

enum AnswerSurfaceReloader {
    static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: answerWidgetKind)
        ControlCenter.shared.reloadControls(ofKind: answerControlKind)
    }
}

/// A system control rather than a custom view: Control Center owns its shape,
/// typography, resizing and iOS 26 Liquid Glass rendering. The answer is both
/// the persistent title at the larger sizes and the momentary status shown
/// when a fetch finishes.
struct AnswerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: answerControlKind,
            provider: AnswerControlProvider()
        ) { value in
            ControlWidgetButton(action: value.intent) {
                Label {
                    Text(verbatim: value.text)
                } icon: {
                    Image(systemName: value.systemImage)
                }
                .controlWidgetActionHint("Answer the last seconds")
                .controlWidgetStatus(LocalizedStringResource(stringLiteral: value.text))
            }
        }
        .displayName("AI Answer")
        .description("Answer the last seconds of the lecture without opening Echo.")
    }
}

struct AnswerControlValue {
    let snapshot: AnswerSnapshot
    let configured: Bool
    let configuration: ControlConfigIntent

    var text: String {
        switch snapshot.state {
        case .idle: configured ? "Tap for answer" : "Setup required"
        case .loading: "Thinking…"
        case .answer, .failure: snapshot.text
        }
    }

    var systemImage: String {
        switch snapshot.state {
        case .idle: configured ? "sparkles" : "gearshape"
        case .loading: "ellipsis"
        case .answer: "text.bubble.fill"
        case .failure: "exclamationmark.triangle"
        }
    }

    var intent: FetchAnswerIntent {
        FetchAnswerIntent(
            host: configuration.host,
            port: configuration.port,
            token: configuration.token,
            contextSeconds: configuration.contextSeconds
        )
    }
}

struct AnswerControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: ControlConfigIntent) -> AnswerControlValue {
        AnswerControlValue(
            snapshot: .init(state: .answer, text: "Paris.", updatedAt: .now),
            configured: true,
            configuration: configuration
        )
    }

    func currentValue(configuration: ControlConfigIntent) async throws -> AnswerControlValue {
        let connection = FetchAnswerIntent.resolveConnection(
            host: configuration.host,
            port: configuration.port,
            token: configuration.token,
            contextSeconds: configuration.contextSeconds
        )
        return AnswerControlValue(
            snapshot: AnswerSnapshotStore.current(),
            configured: connection.isUsable,
            configuration: configuration
        )
    }
}
