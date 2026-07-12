import SwiftUI

@main
struct MossLiveApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// Standard three-tab structure: the live session, the lessons archive on the
/// server, and settings. Jumps to Settings on first launch until the server
/// connection is configured.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab: Tab = .live

    enum Tab: Hashable {
        case live, lessons, settings
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                LiveView().tag(Tab.live)
                LessonsView().tag(Tab.lessons)
                SettingsView().tag(Tab.settings)
            }
            .toolbar(.hidden, for: .tabBar)
            HStack(spacing: 8) {
                tabButton(.live, "Live", "waveform")
                tabButton(.lessons, "Archive", "square.stack.3d.up.fill")
                tabButton(.settings, "Setup", "slider.horizontal.3")
            }
            .padding(8)
            .background(.black)
            .overlay(alignment: .top) { Divider().opacity(0.35) }
        }
        .tint(MossTheme.accent)
        .onAppear {
            if !model.settings.isConfigured {
                selectedTab = .settings
            }
        }
    }

    private func tabButton(_ tab: Tab, _ title: String, _ symbol: String) -> some View {
        Button { selectedTab = tab } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selectedTab == tab ? .black : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(selectedTab == tab ? MossTheme.accent : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
