import Combine
import SwiftUI
import UIKit

@main
struct MossLiveApp: App {
    @State private var model: AppModel

    init() {
        UITestRuntime.installFixtures()
        _model = State(initialValue: AppModel())
        if UITestRuntime.isEnabled {
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(model)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingNoteImportCount = 0
    @State private var noteImportCoordinator = IncomingNoteImportCoordinator()
    @ScaledMetric(relativeTo: .body) private var sidebarFooterRowHeight: CGFloat = 52

    /// Which place the sidebar is on. It lives on the model rather than in this
    /// view so screens can change the selected destination directly.
    private var selection: Binding<AppTab?> {
        Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 })
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.columnVisibility },
            set: { visibility, transaction in
                guard visibility != model.columnVisibility else { return }
                // NotificationCenter publishes synchronously, so the open
                // reader can snapshot its PDF before the first resize frame.
                NotificationCenter.default.post(name: .readerContainerWillResize, object: nil)

                // A custom binding does not automatically carry the system
                // sidebar button's transaction across an observable model
                // write. That is visible when the button is tapped just after
                // a navigation push: the column otherwise jumps straight to
                // its final width. Preserve the supplied transaction and give
                // transaction-less updates their own animation.
                var resizeTransaction = transaction
                if !reduceMotion {
                    resizeTransaction.disablesAnimations = false
                    resizeTransaction.animation = resizeTransaction.animation
                        ?? .smooth(duration: 0.38)
                }
                withTransaction(resizeTransaction) {
                    model.columnVisibility = visibility
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            List(AppTab.navigation, selection: selection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
                    .badge(tab == .stunden ? pendingNoteImportCount : 0)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tab.title)
                    .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFooter
            }
        } detail: {
            selectedView
        }
        .navigationSplitViewStyle(.balanced)
        .background(ThreeFingerSwitch(urlString: model.settings.quickSwitchURL))
        .onOpenURL { url in
            noteImportCoordinator.receive(url, model: model)
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
        .onChange(of: model.sessionId) { _, _ in
            noteImportCoordinator.modelDidChange(model)
        }
        .onChange(of: model.phase) { _, _ in
            noteImportCoordinator.modelDidChange(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pendingNoteImportsChanged)) { _ in
            pendingNoteImportCount = PendingNoteImports.all().count
        }
        .sheet(item: destinationItemBinding, onDismiss: {
            noteImportCoordinator.destinationSheetDismissed()
        }) { item in
            IncomingNoteDestinationView(
                item: item,
                api: model.api,
                coordinator: noteImportCoordinator
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = noteImportCoordinator.status.message,
               noteImportCoordinator.destinationItem == nil {
                IncomingNoteImportBanner(
                    message: message,
                    isError: noteImportCoordinator.status.isFailure,
                    retry: { noteImportCoordinator.retry(model: model) },
                    dismiss: noteImportCoordinator.dismissStatus
                )
                .frame(maxWidth: 440)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var destinationItemBinding: Binding<PendingNoteImports.Item?> {
        Binding(
            get: { noteImportCoordinator.destinationItem },
            set: { item in
                if item == nil { noteImportCoordinator.destinationSheetDismissed() }
            }
        )
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AppTab.einstellungen.title)
                    .accessibilityIdentifier("tab.\(AppTab.einstellungen.rawValue)")
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(height: sidebarFooterRowHeight)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var selectedView: some View {
        switch model.selectedTab ?? .aufnahme {
        case .aufnahme: LiveView()
        case .stunden: LessonsView()
        case .lernen: LearnView()
        case .bibliothek: LibraryView()
        case .chat: ChatView()
        case .einstellungen: SettingsView()
        }
    }
}

private struct IncomingNoteImportBanner: View {
    let message: String
    let isError: Bool
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "doc.badge.arrow.up")
                .foregroundStyle(isError ? .red : Theme.accent)
            Text(message)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 8)
            if isError {
                Button("Erneut", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hinweis schließen")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case aufnahme, stunden, lernen, bibliothek, chat, einstellungen

    var id: Self { self }

    /// What the navigation list holds. Einstellungen is deliberately absent —
    /// it lives pinned at the foot of the sidebar instead.
    static let navigation = allCases.filter { $0 != .einstellungen }

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
