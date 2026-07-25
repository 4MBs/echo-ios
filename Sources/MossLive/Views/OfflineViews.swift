import SwiftUI

/// The one place the app says the word "offline".
///
/// It sits in the sidebar's footer, where Mail keeps the same news, and it is
/// the whole of the treatment: no banners over content, no badges on rows. The
/// screens themselves simply show what they have, and anything the outage
/// actually prevents is greyed out where it is used, with its own reason.
///
/// The footer owns the horizontal inset so this line's icon lands on the same
/// column as the navigation rows above it.
struct SidebarOfflineNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.connectivity.isOnline {
            Label("Offline", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .transition(.opacity)
        }
    }
}
