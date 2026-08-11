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

/// iPad shell: a dedicated, collapsible sidebar using T3 Code mobile's iPad
/// metrics. The content is still Echo's six places, but the column now has the
/// same inset rows, 12pt continuous selection, blue selected state, quiet
/// toolbar settings action and near-opaque system surface as T3's thread pane.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingNoteImportCount = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(AppTab.navigation) { tab in
                            sidebarRow(tab)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }
                .scrollIndicators(.hidden)

                sidebarFooter
            }
            .background(Color(.systemBackground))
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.selectedTab = .einstellungen
                    } label: {
                        Image(systemName: model.selectedTab == .einstellungen
                            ? "gearshape.fill"
                            : "gearshape")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Einstellungen")
                    .accessibilityAddTraits(model.selectedTab == .einstellungen ? .isSelected : [])
                }
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

    private var sidebarFooter: some View {
        SidebarOfflineNote()
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    private func sidebarRow(_ tab: AppTab) -> some View {
        let selected = model.selectedTab == tab
        return Button {
            withAnimation(.snappy) {
                model.selectedTab = tab
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 22)
                Text(tab.title)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if tab == .stunden, pendingNoteImportCount > 0 {
                    Text("\(pendingNoteImportCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            selected ? Color.white.opacity(0.2) : Color(.tertiarySystemFill),
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(
                selected ? Color(.systemBlue) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(T3SidebarPressStyle())
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// T3's sidebar rows keep their selection shape stable and express a press by
/// fading the contents rather than introducing a second custom surface.
private struct T3SidebarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case aufnahme, stunden, lernen, bibliothek, chat, einstellungen

    var id: Self { self }

    /// What the navigation list holds. Einstellungen is deliberately absent —
    /// like T3 Code, it is reached from the sidebar's toolbar gear instead.
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
