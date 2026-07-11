import SwiftUI

@main
struct MossLiveApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(model)
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
        TabView(selection: $selectedTab) {
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform") }
                .tag(Tab.live)
            LessonsView()
                .tabItem { Label("Lessons", systemImage: "books.vertical.fill") }
                .tag(Tab.lessons)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(.purple)
        .onAppear {
            if !model.settings.isConfigured {
                selectedTab = .settings
            }
        }
    }
}
