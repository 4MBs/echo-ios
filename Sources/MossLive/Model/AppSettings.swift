import Foundation
import Security

/// User-configurable settings. The server address & co. live in UserDefaults;
/// the auth token lives in the Keychain.
@Observable
final class AppSettings {
    var serverHost: String {
        didSet {
            defaults.set(serverHost, forKey: "serverHost")
            mirrorToWidget()
        }
    }

    var serverPort: Int {
        didSet {
            defaults.set(serverPort, forKey: "serverPort")
            mirrorToWidget()
        }
    }

    var authToken: String {
        didSet {
            Keychain.set(authToken, account: "mosslive-auth-token")
            mirrorToWidget()
        }
    }

    var contextSeconds: Double {
        didSet {
            defaults.set(contextSeconds, forKey: "contextSeconds")
            mirrorToWidget()
        }
    }

    var bitrate: Int {
        didSet { defaults.set(bitrate, forKey: "bitrate") }
    }

    /// Tier 4: notify at the start of each lesson so recording is one tap away.
    var lessonNotifications: Bool {
        didSet { defaults.set(lessonNotifications, forKey: "lessonNotifications") }
    }

    /// Tier 4: automatically stop recording when the current lesson ends.
    var autoStopAtLessonEnd: Bool {
        didSet { defaults.set(autoStopAtLessonEnd, forKey: "autoStopAtLessonEnd") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverHost = defaults.string(forKey: "serverHost") ?? ""
        let port = defaults.integer(forKey: "serverPort")
        serverPort = port == 0 ? 8787 : port
        authToken = Keychain.get(account: "mosslive-auth-token") ?? ""
        let ctx = defaults.double(forKey: "contextSeconds")
        contextSeconds = ctx == 0 ? 30 : ctx
        let rate = defaults.integer(forKey: "bitrate")
        bitrate = rate == 0 ? 24000 : rate
        lessonNotifications = defaults.bool(forKey: "lessonNotifications")
        autoStopAtLessonEnd = defaults.bool(forKey: "autoStopAtLessonEnd")
        // propagate whatever is already configured to the widget container,
        // so widgets work immediately after this app version's first launch
        mirrorToWidget()
    }

    /// Keeps the widget's App Group container in sync so widgets need no
    /// per-widget configuration.
    private func mirrorToWidget() {
        SharedConfig.write(
            host: serverHost,
            port: serverPort,
            token: authToken,
            contextSeconds: Int(contextSeconds)
        )
    }

    var isConfigured: Bool {
        !serverHost.trimmingCharacters(in: .whitespaces).isEmpty && !authToken.isEmpty
    }

    var websocketURL: URL? {
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = serverHost.trimmingCharacters(in: .whitespaces)
        comps.port = serverPort
        comps.path = "/ws/stream"
        return comps.url
    }
}

/// Minimal Keychain wrapper for the shared auth token.
enum Keychain {
    private static let service = "com.fourmbs.mosslive"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
