import SwiftUI

@main
struct MossLiveApp: App {
    @State private var model = AppModel()

    init() {
        // Handwritten screen titles (mockup style). Noteworthy ships with
        // iOS, so no font files are bundled.
        let bar = UINavigationBar.appearance()
        if let title = UIFont(name: "Noteworthy-Bold", size: 19) {
            bar.titleTextAttributes = [.font: title]
        }
        if let large = UIFont(name: "Noteworthy-Bold", size: 32) {
            bar.largeTitleTextAttributes = [.font: large]
        }
    }

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environment(model)
                .tint(Theme.accent)
                // The notebook design is built for its paper look; iOS dark
                // mode made it muddy, so the app keeps its own appearance
                // regardless of the system setting.
                .preferredColorScheme(.light)
        }
    }
}

/// iPad shell: ink-dark sidebar (Aufnahme, Stunden, Lernen, Chat,
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
        .background {
            // Worn notebook cover: dark leather-brown paper scan over the
            // ink base, so the sidebar belongs to the same paper world.
            Theme.sidebar
                .overlay(
                    Image("paper-dark")
                        .resizable()
                        .scaledToFill()
                        .opacity(0.85)
                )
                .clipped()
                .ignoresSafeArea()
        }
        .navigationBarHidden(true)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 280)
    }

    private static let coverText = Color(red: 0.93, green: 0.89, blue: 0.80)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Self.coverText, Theme.accent)
            Text("Echo")
                .font(Theme.handwriting(26))
                .foregroundStyle(Self.coverText)
            if model.phase == .recording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Nimmt auf")
                        .font(.caption)
                        .foregroundStyle(Self.coverText.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// Selected row = a cream paper label stuck onto the dark cover.
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
            .foregroundStyle(selection == item ? Theme.ink : Self.coverText.opacity(0.72))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if selection == item {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.card)
                        .overlay(
                            Image("paper-card")
                                .resizable()
                                .scaledToFill()
                                .opacity(0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        .rotationEffect(.degrees(-0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
