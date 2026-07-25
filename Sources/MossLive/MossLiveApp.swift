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

    /// Measured off Apple's own sidebars rather than guessed: TV and Podcasts
    /// both step 44pt from one row to the next, which is the standard iOS row
    /// height and the smallest thing the guidelines call tappable. SwiftUI adds
    /// about four points above and below the label by default, and that is the
    /// whole of why this column read looser than theirs.
    private static let rowHeight: CGFloat = 44

    /// The list keeps a margin from the sidebar edge — the selection capsule
    /// starts there — and insets the row's content within it. Both are named so
    /// the pinned footer can line its icon up with the list's.
    private static let listMargin: CGFloat = 10
    private static let rowInset: CGFloat = 20

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(AppTab.navigation, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .frame(height: Self.rowHeight)
                    .listRowInsets(
                        EdgeInsets(
                            top: 0, leading: Self.rowInset,
                            bottom: 0, trailing: Self.rowInset
                        )
                    )
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 300)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFooter
            }
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

    /// Settings sits under the navigation list rather than inside it. It is not
    /// one of the places this app keeps things, so as a peer of Stunden and
    /// Bibliothek it carried a weight it had not earned — and pinning it gives
    /// the column the bottom edge it was missing. The offline line shares the
    /// footer, which is where Apple keeps what is true of the whole app rather
    /// than of one screen.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarOfflineNote()
                .padding(.horizontal, Self.rowInset)
            settingsRow
        }
        .padding(.horizontal, Self.listMargin)
        .padding(.bottom, 6)
    }

    private var settingsRow: some View {
        let selected = selection == .einstellungen
        return Button {
            selection = .einstellungen
        } label: {
            Label(AppTab.einstellungen.title, systemImage: AppTab.einstellungen.systemImage)
                .padding(.horizontal, Self.rowInset)
                .frame(height: Self.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(selected ? Theme.accent : Color.primary)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
        // A calendar, not a bookshelf: this tab holds one folder per school
        // day. The shelf read as books, and Bibliothek two rows below is
        // books — two book glyphs in a list of five is one too many.
        case .stunden: "calendar"
        case .lernen: "brain.head.profile"
        case .bibliothek: "book.closed"
        case .chat: "bubble.left.and.text.bubble.right"
        case .einstellungen: "gearshape"
        }
    }
}
