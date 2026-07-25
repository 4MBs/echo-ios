import SwiftUI

/// Einstellungen, arranged the way iOS arranges its own: an index of
/// destinations, each with one subject, rather than a single page carrying
/// every control in the app with a paragraph of explanation under each of
/// them. What a row is currently set to is shown on the row, so the common
/// question — "is the server in?", "when does it remind me?" — is answered
/// without opening anything.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        SettingsRow(
                            title: "Server",
                            systemImage: "server.rack",
                            tint: .blue,
                            value: serverValue
                        )
                    }
                    NavigationLink {
                        TimetableSettingsView()
                    } label: {
                        SettingsRow(
                            title: "Stundenplan",
                            systemImage: "calendar",
                            tint: .red,
                            value: model.timetable.enabled ? "WebUntis" : "Aus"
                        )
                    }
                }

                Section {
                    NavigationLink {
                        RecordingSettingsView()
                    } label: {
                        SettingsRow(title: "Aufnahme", systemImage: "waveform", tint: .pink)
                    }
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        SettingsRow(title: "KI", systemImage: "sparkles", tint: .purple)
                    }
                }

                Section {
                    NavigationLink {
                        LearnSettingsView()
                    } label: {
                        SettingsRow(
                            title: "Lernen",
                            systemImage: "brain.head.profile",
                            tint: .orange,
                            value: reminderValue
                        )
                    }
                    NavigationLink {
                        LibrarySettingsView()
                    } label: {
                        SettingsRow(title: "Bibliothek", systemImage: "book.closed", tint: .brown)
                    }
                    NavigationLink {
                        QuickSwitchSettingsView()
                    } label: {
                        SettingsRow(
                            title: "App-Wechsel",
                            systemImage: "hand.tap",
                            tint: .teal,
                            value: QuickSwitchApp(urlString: model.settings.quickSwitchURL).title
                        )
                    }
                }

                Section {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        SettingsRow(
                            title: "Über Echo",
                            systemImage: "info",
                            tint: .gray,
                            value: AppInfo.version
                        )
                    }
                }
            }
            // Explicit, because this list lives in the detail column of a
            // split view, where the automatic style is not the grouped one.
            .listStyle(.insetGrouped)
            .navigationTitle("Einstellungen")
            .task { await model.refreshTimetable() }
        }
    }

    private var serverValue: String {
        let host = model.settings.serverHost.trimmingCharacters(in: .whitespaces)
        guard model.settings.isConfigured, !host.isEmpty else { return "Nicht eingerichtet" }
        return host
    }

    private var reminderValue: String {
        let settings = model.settings
        guard settings.learnReminderEnabled else { return "Aus" }
        let date = Calendar.current.date(
            bySettingHour: settings.learnReminderMinutes / 60,
            minute: settings.learnReminderMinutes % 60,
            second: 0,
            of: .now
        )
        return date?.formatted(date: .omitted, time: .shortened) ?? "An"
    }
}

// MARK: - The index's rows

/// One row of the index: a tinted glyph, the name, and — where there is one —
/// what it is currently set to, which is exactly how iOS builds its own.
struct SettingsRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlyph(systemImage: systemImage, tint: tint)
            Text(title)
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// The rounded, filled tile iOS puts at the head of a settings row. Fixed at
/// 29pt like the system's, so the titles line up down the column.
struct SettingsGlyph: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

enum AppInfo {
    /// Marketing version and build, the way About screens spell it.
    static var version: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
