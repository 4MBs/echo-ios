import SwiftUI

/// Echo's settings index uses the same hierarchy and measurements as T3 Code
/// mobile's settings sheet, translated from React Native to native SwiftUI:
/// 20pt screen margins, 24pt gaps, 24pt continuous cards, monochrome 22pt
/// symbols, and quiet trailing values. Destinations remain Echo-specific.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    T3SettingsSection("Konfiguration") {
                        T3SettingsLink(
                            title: "Server",
                            systemImage: "server.rack",
                            value: serverValue
                        ) {
                            ServerSettingsView()
                        }
                        T3SettingsLink(
                            title: "Stundenplan",
                            systemImage: "calendar",
                            value: model.timetable.enabled ? "WebUntis" : "Aus"
                        ) {
                            TimetableSettingsView()
                        }
                    }

                    T3SettingsSection("Aufnahme & KI") {
                        T3SettingsLink(title: "Aufnahme", systemImage: "waveform") {
                            RecordingSettingsView()
                        }
                        T3SettingsLink(title: "KI", systemImage: "sparkles") {
                            AISettingsView()
                        }
                    }

                    T3SettingsSection("Lernen") {
                        T3SettingsLink(
                            title: "Lernen",
                            systemImage: "brain.head.profile",
                            value: learnValue
                        ) {
                            LearnSettingsView()
                        }
                        T3SettingsLink(title: "Bibliothek", systemImage: "book.closed") {
                            LibrarySettingsView()
                        }
                        T3SettingsLink(
                            title: "App-Wechsel",
                            systemImage: "hand.tap",
                            value: QuickSwitchApp(urlString: model.settings.quickSwitchURL).title
                        ) {
                            QuickSwitchSettingsView()
                        }
                    }

                    T3SettingsSection("App") {
                        T3SettingsLink(
                            title: "Über Echo",
                            systemImage: "info.circle",
                            value: AppInfo.version
                        ) {
                            AboutSettingsView()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 36)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .groupedScreen()
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.refreshTimetable() }
        }
    }

    private var serverValue: String {
        let host = model.settings.serverHost.trimmingCharacters(in: .whitespaces)
        guard model.settings.isConfigured, !host.isEmpty else { return "Nicht eingerichtet" }
        return host
    }

    private var learnValue: String {
        let settings = model.settings
        let goal = "\(settings.dailyLearnMinutes) Min"
        guard settings.learnReminderEnabled else { return goal }
        let date = Calendar.current.date(
            bySettingHour: settings.learnReminderMinutes / 60,
            minute: settings.learnReminderMinutes % 60,
            second: 0,
            of: .now
        )
        guard let time = date?.formatted(date: .omitted, time: .shortened) else { return goal }
        return "\(goal) · \(time)"
    }
}

/// SwiftUI counterpart of T3 Code's `SettingsSection`: a quiet section label
/// above one uninterrupted card rather than a stack of individually decorated
/// controls.
struct T3SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                content
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

/// SwiftUI counterpart of T3 Code's `SettingsRow`: monochrome leading symbol,
/// 18pt label, muted value and a small system chevron.
private struct T3SettingsRow: View {
    let title: String
    let systemImage: String
    let value: String?

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 18))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let value {
                Text(value)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct T3SettingsLink<Destination: View>: View {
    let title: String
    let systemImage: String
    let value: String?
    let destination: Destination

    init(
        title: String,
        systemImage: String,
        value: String? = nil,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            T3SettingsRow(title: title, systemImage: systemImage, value: value)
        }
        .buttonStyle(T3SettingsPressStyle())
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
    }
}

private struct T3SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.tertiarySystemFill) : .clear)
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

enum AppInfo {
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
