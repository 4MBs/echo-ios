import Foundation

/// Server connection settings shared between the app and the widget extension
/// through an App Group container, so the widget works with **zero
/// configuration** — whatever is entered in the app's Settings is what the
/// widget uses.
///
/// This file is compiled into BOTH targets.
///
/// If the sideloading tool fails to carry the app-group entitlement through
/// its re-signing, `UserDefaults(suiteName:)` silently returns a non-shared
/// container; the widget then falls back to its own per-widget parameters
/// (long-press → Edit Widget), which always work.
enum SharedConfig {
    static let appGroupID = "group.com.fourmbs.mosslive"

    struct Connection {
        var host: String
        var port: Int
        var token: String
        var contextSeconds: Int

        var isUsable: Bool {
            !host.trimmingCharacters(in: .whitespaces).isEmpty && !token.isEmpty
        }
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func write(host: String, port: Int, token: String, contextSeconds: Int) {
        guard let defaults else { return }
        defaults.set(host, forKey: "serverHost")
        defaults.set(port, forKey: "serverPort")
        defaults.set(token, forKey: "authToken")
        defaults.set(contextSeconds, forKey: "contextSeconds")
    }

    static func read() -> Connection {
        guard let defaults else {
            return Connection(host: "", port: 8787, token: "", contextSeconds: 30)
        }
        let port = defaults.integer(forKey: "serverPort")
        let ctx = defaults.integer(forKey: "contextSeconds")
        return Connection(
            host: defaults.string(forKey: "serverHost") ?? "",
            port: port == 0 ? 8787 : port,
            token: defaults.string(forKey: "authToken") ?? "",
            contextSeconds: ctx == 0 ? 30 : ctx
        )
    }
}
