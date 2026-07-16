import SwiftUI

@main
struct MossLiveApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environment(model)
                .tint(Theme.accent)
        }
    }
}

/// iPad shell: navy sidebar (Aufnahme · Stunden · Chat · Zusammenfassungen ·
/// Einstellungen) with the notebook-style content on the right. Jumps to
/// Einstellungen on first launch until the server connection is configured.
struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem = .aufnahme

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            switch selection {
            case .aufnahme: LiveView()
            case .stunden: LessonsView()
            case .lernen: LearnView()
            case .chat: ChatView()
            case .einstellungen: SettingsView()
            }
        }
        .background(ThreeFingerSwitch(urlString: model.settings.quickSwitchURL))
        .onAppear {
            if !model.settings.isConfigured {
                selection = .einstellungen
            }
        }
    }
}

enum SidebarItem: Hashable, CaseIterable {
    case aufnahme, stunden, lernen, chat, einstellungen

    var title: String {
        switch self {
        case .aufnahme: "Aufnahme"
        case .stunden: "Stunden"
        case .lernen: "Lernen"
        case .chat: "Chat mit KI"
        case .einstellungen: "Einstellungen"
        }
    }

    var icon: String {
        switch self {
        case .aufnahme: "waveform"
        case .stunden: "books.vertical.fill"
        case .lernen: "brain.head.profile"
        case .chat: "bubble.left.and.text.bubble.right"
        case .einstellungen: "gearshape.fill"
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .padding(.top, 18)
                .padding(.bottom, 22)

            ForEach([SidebarItem.aufnahme, .stunden, .lernen, .chat], id: \.self) { item in
                row(item)
            }

            Spacer(minLength: 0)

            Divider()
                .overlay(Color.white.opacity(0.15))
                .padding(.vertical, 6)
            row(.einstellungen)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebarNavy.ignoresSafeArea())
        .navigationBarHidden(true)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white, Theme.sidebarSelection)
            Text("Echo")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            if model.phase == .recording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Nimmt auf")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func row(_ item: SidebarItem) -> some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.subheadline)
                    .frame(width: 22)
                Text(item.title)
                    .font(.subheadline.weight(selection == item ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selection == item ? .white : .white.opacity(0.65))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                selection == item ? Theme.sidebarSelection : .clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
