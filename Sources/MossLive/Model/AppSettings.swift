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

    /// Level the recording ourselves instead of leaving it to iOS.
    ///
    /// iOS's automatic gain control winds the gain up in every pause and lifts
    /// the room with it — measured against Voice Memos on the same iPad in the
    /// same room, that costs 16 dB between speech and the noise floor. Ours only
    /// adapts while somebody is speaking.
    ///
    /// A switch rather than a straight replacement, because the AGC is also what
    /// lifts a teacher eight metres away. One lesson each way settles that; no
    /// measurement on this side can.
    var cleanCapture: Bool {
        didSet { defaults.set(cleanCapture, forKey: "cleanCapture") }
    }

    /// How far that levelling may push, in dB. The room decides the right
    /// value, so it is a setting rather than a constant.
    var captureGainDb: Int {
        didSet { defaults.set(captureGainDb, forKey: "captureGainDb") }
    }

    /// Tier 4: notify at the start of each lesson so recording is one tap away.
    var lessonNotifications: Bool {
        didSet { defaults.set(lessonNotifications, forKey: "lessonNotifications") }
    }

    /// Tier 4: automatically stop recording when the current lesson ends.
    var autoStopAtLessonEnd: Bool {
        didSet { defaults.set(autoStopAtLessonEnd, forKey: "autoStopAtLessonEnd") }
    }

    /// Whether the server last reported a working WebUntis login. Remembered
    /// here so that being unable to ask does not look like never having logged
    /// in — the credentials are on the server and are still perfectly valid.
    var timetableConnected: Bool {
        didSet { defaults.set(timetableConnected, forKey: "timetableConnected") }
    }

    /// URL scheme opened by the three-finger tap (instant app switch).
    var quickSwitchURL: String {
        didSet { defaults.set(quickSwitchURL, forKey: "quickSwitchURL") }
    }

    /// The name the Lernen dashboard says hello to.
    ///
    /// Not an account and not a login — the app has neither. It is a name to be
    /// called by, so the screen opens with a sentence addressed to someone
    /// instead of a heading addressed to nobody. Blank falls back rather than
    /// greeting an empty space, which is why every reader goes through
    /// `greetingName`.
    var displayName: String {
        didSet { defaults.set(displayName, forKey: "displayName") }
    }

    /// What to actually put after "Hallo," — the typed name, or the default
    /// when the field has been emptied.
    var greetingName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultDisplayName : trimmed
    }

    static let defaultDisplayName = "Bot"

    /// Daily "Zeit zum Lernen" reminder for due spaced-repetition cards.
    var learnReminderEnabled: Bool {
        didSet { defaults.set(learnReminderEnabled, forKey: "learnReminderEnabled") }
    }

    /// Reminder time as minutes since midnight (default 16:00).
    var learnReminderMinutes: Int {
        didSet { defaults.set(learnReminderMinutes, forKey: "learnReminderMinutes") }
    }

    /// How far the record control's colours are turned around the wheel. Stored
    /// as the shift itself rather than a name, so the set of offered colours can
    /// change without stranding a saved value.
    var recordButtonHue: Double {
        didSet { defaults.set(recordButtonHue, forKey: "recordButtonHue") }
    }

    /// Whether a book shows the control for adjusting its page numbering. Off
    /// once the books are lined up: the numbering each book already learned
    /// stays in force either way, this only takes the control off the screen.
    var showPageNumberEditor: Bool {
        didSet { defaults.set(showPageNumberEditor, forKey: "showPageNumberEditor") }
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
        // on until switched off: it is the measured-better setting, and the
        // switch exists to disprove that on a real lesson, not to opt into it
        cleanCapture = defaults.object(forKey: "cleanCapture") as? Bool ?? true
        let gain = defaults.integer(forKey: "captureGainDb")
        captureGainDb = gain == 0 ? 24 : gain
        displayName = defaults.string(forKey: "displayName") ?? Self.defaultDisplayName
        lessonNotifications = defaults.bool(forKey: "lessonNotifications")
        autoStopAtLessonEnd = defaults.bool(forKey: "autoStopAtLessonEnd")
        timetableConnected = defaults.bool(forKey: "timetableConnected")
        learnReminderEnabled = defaults.bool(forKey: "learnReminderEnabled")
        // on until switched off, unlike the other flags
        showPageNumberEditor = defaults.object(forKey: "showPageNumberEditor") as? Bool ?? true
        recordButtonHue = defaults.double(forKey: "recordButtonHue")  // 0 = the red it was designed in
        let reminderMinutes = defaults.integer(forKey: "learnReminderMinutes")
        learnReminderMinutes = reminderMinutes == 0 ? 16 * 60 : reminderMinutes
        // migrate the old default: bare goodnotes:// lands in GoodNotes'
        // file-import handler and shows an "unsupported file type" alert;
        // the legacy launcher scheme opens the app silently
        let storedQuickSwitch = defaults.string(forKey: "quickSwitchURL")
        quickSwitchURL = (storedQuickSwitch == nil || storedQuickSwitch == "goodnotes://")
            ? "goodnotes5://" : storedQuickSwitch!
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
