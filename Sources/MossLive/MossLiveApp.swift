import Combine
import SwiftUI

@main
struct MossLiveApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(model)
        }
        // Make the iPad's top-level places reachable without leaving the page.
        // These appear in the system shortcut HUD when Command is held.
        .commands {
            CommandMenu("Bereiche") {
                Button("Aufnahme", systemImage: "waveform") { model.selectedTab = .aufnahme }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Stunden", systemImage: "folder") { model.selectedTab = .stunden }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Lernen", systemImage: "brain.head.profile") { model.selectedTab = .lernen }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Bibliothek", systemImage: "book.closed") { model.selectedTab = .bibliothek }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Chat mit KI", systemImage: "bubble.left.and.text.bubble.right") {
                    model.selectedTab = .chat
                }
                .keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("Einstellungen", systemImage: "gearshape") { model.selectedTab = .einstellungen }
                    .keyboardShortcut("6", modifiers: .command)
            }
        }
    }
}

/// iPad shell: a dedicated, collapsible system sidebar. Unlike an adaptable
/// tab view, this never turns the app navigation into a bar across the top.
///
/// The rows are the system's, not ours. This column used to set its own row
/// height, its own insets and its own selection capsule, all measured off
/// screenshots of Apple's sidebars. Under the new design a sidebar is a
/// floating Liquid Glass surface the system styles, lights and insets itself,
/// and hand-set metrics fight that rather than match it — the platform adapts,
/// and anything pinned to last year's numbers stops adapting with it.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingNoteImportCount = 0

    /// Which place the sidebar is on. It lives on the model rather than in this
    /// view so a screen can send the student somewhere — Lernen with no cards
    /// yet offers "Zur Aufnahme", and that has to actually go there.
    private var selection: Binding<AppTab?> {
        Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(AppTab.navigation, selection: selection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
                    .badge(tab == .stunden ? pendingNoteImportCount : 0)
            }
            .listStyle(.sidebar)
            .navigationTitle("Echo")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFooter
            }
        } detail: {
            selectedView
        }
        .navigationSplitViewStyle(.balanced)
        .background(ThreeFingerSwitch(urlString: model.settings.quickSwitchURL))
        // Studying covers the whole window, from wherever it was started: the
        // Lernen screen, a subject board or a single lesson. It is a mode, not a
        // place, so it hides the sidebar and has exactly one way out.
        .fullScreenCover(
            isPresented: Binding(
                get: { model.studySession != nil },
                set: { if !$0 { model.endStudy() } }
            )
        ) {
            if let session = model.studySession {
                StudySessionView(session: session)
                    .environment(model)
            }
        }
        .onAppear {
            pendingNoteImportCount = PendingNoteImports.all().count
            if !model.settings.isConfigured {
                model.selectedTab = .einstellungen
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                pendingNoteImportCount = PendingNoteImports.all().count
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pendingNoteImportsChanged)) { _ in
            pendingNoteImportCount = PendingNoteImports.all().count
        }
    }

    /// Settings sits under the navigation list rather than inside it. It is not
    /// one of the places this app keeps things, so as a peer of Stunden and
    /// Bibliothek it carried a weight it had not earned — and pinning it gives
    /// the column the bottom edge it was missing. The offline line shares the
    /// footer, which is where Apple keeps what is true of the whole app rather
    /// than of one screen.
    ///
    /// It is a `List` of one rather than a button dressed as a row, so its
    /// height, its insets and its selection are the same system-drawn things as
    /// the rows above it — previously they were a hand-drawn approximation that
    /// only matched at one point size, in one appearance, on one iPad.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarOfflineNote()
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            List(selection: selection) {
                Label(AppTab.einstellungen.title, systemImage: AppTab.einstellungen.systemImage)
                    .tag(AppTab.einstellungen)
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(height: 52)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var selectedView: some View {
        switch model.selectedTab ?? .aufnahme {
        case .aufnahme: LiveView()
        case .stunden: LessonsView()
        case .lernen: TodayView()
        case .bibliothek: LibraryView()
        case .chat: ChatView()
        case .einstellungen: SettingsView()
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case aufnahme, stunden, lernen, bibliothek, chat, einstellungen

    var id: Self { self }

    /// What the navigation list holds. Einstellungen is deliberately absent —
    /// it lives pinned at the foot of the sidebar instead.
    static var navigation: [AppTab] {
        allCases.filter { $0 != .einstellungen }
    }

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
        // A folder, not a bookshelf: this tab holds one folder per subject.
        // The shelf read as books, and Bibliothek two rows below is books —
        // two book glyphs in a list of five is one too many.
        case .stunden: "folder"
        case .lernen: "brain.head.profile"
        case .bibliothek: "book.closed"
        case .chat: "bubble.left.and.text.bubble.right"
        case .einstellungen: "gearshape"
        }
    }
}
