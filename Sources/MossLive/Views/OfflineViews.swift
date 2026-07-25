import SwiftUI

/// The strip a screen wears while the server is out of reach.
///
/// It says two things, and only these two: that what is on the screen came off
/// the iPad rather than the server, and how old it is. Anything the outage
/// actually prevents says so at the point where it is prevented — a greyed-out
/// button with a reason under it beats a banner listing what no longer works.
struct OfflineBar: View {
    /// When the content below was last fetched, if it came from the cache.
    var savedAt: Date?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "wifi.slash")
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        guard let savedAt else { return "Offline" }
        return "Offline · Stand \(CacheAge.phrase(savedAt))"
    }
}

/// Why something on the screen is switched off. Small, grey, directly under the
/// control it explains.
struct OfflineHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// Hangs the offline strip above a screen while the server is unreachable,
    /// and takes up no room at all while it is not.
    func offlineBar(savedAt: Date? = nil) -> some View {
        modifier(OfflineBarModifier(savedAt: savedAt))
    }
}

private struct OfflineBarModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let savedAt: Date?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.connectivity.isOnline {
                    OfflineBar(savedAt: savedAt)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.connectivity.isOnline)
    }
}
