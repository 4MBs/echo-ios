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

/// iPad shell: a dedicated, collapsible system sidebar. Unlike an adaptable
/// tab view, this never turns the app navigation into a bar across the top.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppTab? = .aufnahme
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                // Three groups rather than one flat run of six: what a lesson
                // goes through, what it is read alongside, and the settings.
                Section {
                    row(.aufnahme)
                    row(.stunden)
                    row(.lernen)
                }
                Section {
                    row(.bibliothek)
                    row(.chat)
                }
                Section {
                    row(.einstellungen)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Echo")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            selectedView
        }
        .navigationSplitViewStyle(.balanced)
        .background(ThreeFingerSwitch(urlString: model.settings.quickSwitchURL))
        .onAppear {
            if !model.settings.isConfigured {
                selection = .einstellungen
            }
        }
    }

    /// A sidebar row. Aufnahme carries a blinking dot while a recording is
    /// running, so the state is visible from every other screen in the app.
    private func row(_ tab: AppTab) -> some View {
        HStack(spacing: 0) {
            Label(tab.title, systemImage: tab.systemImage)
            Spacer(minLength: 8)
            if tab == .aufnahme, model.phase == .recording {
                RecordingDot()
            }
        }
        .tag(tab)
    }

    @ViewBuilder
    private var selectedView: some View {
        switch selection ?? .aufnahme {
        case .aufnahme: LiveView()
        case .stunden: LessonsView()
        case .lernen: LearnView()
        case .bibliothek: LibraryView()
        case .chat: ChatView()
        case .einstellungen: SettingsView()
        }
    }
}

/// Blinks while a recording is running. The only moving thing in the sidebar,
/// and the reason you cannot leave a lesson recording by accident.
private struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel("Aufnahme läuft")
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case aufnahme, stunden, lernen, bibliothek, chat, einstellungen

    var id: Self { self }

    var title: String {
        switch self {
        case .aufnahme: "Aufnahme"
        case .stunden: "Stunden"
        case .lernen: "Lernen"
        case .bibliothek: "Bibliothek"
        case .chat: "Chat mit KI"
        case .einstellungen: "Einstellungen"
        }
    }

    var systemImage: String {
        switch self {
        case .aufnahme: "waveform"
        // not a second book icon: Bibliothek owns that shelf
        case .stunden: "list.bullet.rectangle"
        case .lernen: "brain.head.profile"
        case .bibliothek: "book.closed"
        case .chat: "bubble.left.and.text.bubble.right"
        case .einstellungen: "gearshape"
        }
    }
}
