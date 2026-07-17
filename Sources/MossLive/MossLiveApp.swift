import SwiftUI

@main
struct MossLiveApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environment(model)
        }
    }
}

/// iPad shell: native sidebar (Aufnahme, Stunden, Lernen, Chat,
/// Einstellungen) with the selected screen in the detail column. Jumps to
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
        // The id must sit on the split view itself: its detail column is a
        // UIKit navigation controller that keeps pushed screens (a day in
        // Stunden) alive across detail swaps, so an id on the detail content
        // alone replaced the root underneath while the pushed screen stayed
        // on top. Recreating the whole split view drops that stack.
        .id(selection)
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
        case .stunden: "books.vertical"
        case .lernen: "brain.head.profile"
        case .chat: "bubble.left.and.text.bubble.right"
        case .einstellungen: "gearshape"
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                ForEach([SidebarItem.aufnahme, .stunden, .lernen, .chat], id: \.self) { item in
                    row(item)
                }
            }
            Section {
                row(.einstellungen)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Echo")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }

    /// List selection is optional; the app always has a selected screen, so
    /// a deselect tap keeps the current one.
    private var selectionBinding: Binding<SidebarItem?> {
        Binding(get: { selection }, set: { selection = $0 ?? selection })
    }

    private func row(_ item: SidebarItem) -> some View {
        HStack {
            Label(item.title, systemImage: item.icon)
            if item == .aufnahme, model.phase == .recording {
                Spacer()
                Image(systemName: "record.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Nimmt auf")
            }
        }
        .tag(item)
    }
}
