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

/// iPad shell: the system tab experience (adaptable sidebar, like Files or
/// Music). Every tab keeps its own navigation stack alive, so switching is
/// instant and state is preserved — the same behavior as Apple's apps.
/// Jumps to Einstellungen on first launch until the server is configured.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppTab = .aufnahme

    var body: some View {
        TabView(selection: $selection) {
            Tab("Aufnahme", systemImage: "waveform", value: .aufnahme) {
                LiveView()
            }
            Tab("Stunden", systemImage: "books.vertical", value: .stunden) {
                LessonsView()
            }
            Tab("Lernen", systemImage: "brain.head.profile", value: .lernen) {
                LearnView()
            }
            Tab("Bibliothek", systemImage: "book.closed", value: .bibliothek) {
                LibraryView()
            }
            Tab("Chat mit KI", systemImage: "bubble.left.and.text.bubble.right", value: .chat) {
                ChatView()
            }
            Tab("Einstellungen", systemImage: "gearshape", value: .einstellungen) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background(ThreeFingerSwitch(urlString: model.settings.quickSwitchURL))
        .onAppear {
            if !model.settings.isConfigured {
                selection = .einstellungen
            }
        }
    }
}

enum AppTab: Hashable {
    case aufnahme, stunden, lernen, bibliothek, chat, einstellungen
}
