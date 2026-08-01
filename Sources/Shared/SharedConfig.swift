import Foundation

/// Server connection settings shared between the app and the widget extension
/// through an App Group container, so the widget works with **zero
/// configuration** — whatever is entered in the app's Settings is what the
/// widget uses.
///
/// This file is compiled into BOTH targets.
///
/// Sideloading tools (SideStore/AltStore) **rewrite app-group IDs** during
/// re-signing to fit the user's personal team (e.g.
/// `group.com.fourmbs.mosslive.ABC123`), so the group must never be assumed
/// to keep its original name. The actually-granted ID is read at runtime from
/// the bundle's embedded provisioning profile; the original ID is only the
/// fallback (Xcode/simulator builds, where no rewriting happens).
enum SharedConfig {
    static let originalGroupID = "group.com.fourmbs.mosslive"

    struct Connection {
        var host: String
        var port: Int
        var token: String
        var contextSeconds: Int

        var isUsable: Bool {
            !host.trimmingCharacters(in: .whitespaces).isEmpty && !token.isEmpty
        }
    }

    /// The app-group ID this process was actually granted, resolved once.
    /// `nil` means the signer stripped app groups entirely — sharing is then
    /// impossible and the widget needs its per-widget parameters.
    static let resolvedGroupID: String? = {
        guard let entitlements = provisioningProfileEntitlements() else {
            // no embedded profile: Xcode/simulator build, no rewriting happened
            return originalGroupID
        }
        let groups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
        // profile present but no groups -> the signer stripped them: sharing
        // is genuinely unavailable, and pretending otherwise hides the failure
        guard !groups.isEmpty else { return nil }
        // prefer the rewritten descendant of our group if present
        return groups.first { $0.contains("mosslive") } ?? groups.first
    }()

    /// Shared files used by extensions. Unlike `UserDefaults`, a document has
    /// to live in the App Group container itself so it survives after the
    /// short-lived share extension exits.
    static var containerURL: URL? {
        guard let id = resolvedGroupID else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    private static var defaults: UserDefaults? {
        guard let id = resolvedGroupID else { return nil }
        return UserDefaults(suiteName: id)
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

    // MARK: - Provisioning profile parsing

    /// Extracts the Entitlements dict from this bundle's
    /// `embedded.mobileprovision` (a CMS envelope containing a plist).
    /// Sideloaded apps and their extensions each carry one; Xcode and
    /// simulator builds do not (-> nil).
    private static func provisioningProfileEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound ..< data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound ..< end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        return dict["Entitlements"] as? [String: Any]
    }
}
