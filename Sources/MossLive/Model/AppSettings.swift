import Foundation
import Security

/// User-configurable settings. The server address & co. live in UserDefaults;
/// the auth token lives in the Keychain.
@Observable
final class AppSettings {
    var serverHost: String {
        didSet { defaults.set(serverHost, forKey: "serverHost") }
    }
    var serverPort: Int {
        didSet { defaults.set(serverPort, forKey: "serverPort") }
    }
    var authToken: String {
        didSet { Keychain.set(authToken, account: "mosslive-auth-token") }
    }
    var contextSeconds: Double {
        didSet { defaults.set(contextSeconds, forKey: "contextSeconds") }
    }
    var bitrate: Int {
        didSet { defaults.set(bitrate, forKey: "bitrate") }
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
