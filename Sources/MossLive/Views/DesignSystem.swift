import SwiftUI

enum MossTheme {
    static let accent = Color(red: 0.35, green: 0.95, blue: 0.72)
    static let assistant = Color(red: 0.64, green: 0.55, blue: 1.0)
    static let surface = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let raisedSurface = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let cornerRadius: CGFloat = 24
}

struct MossBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.035, green: 0.04, blue: 0.055), Color.black],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(MossTheme.assistant.opacity(0.13))
                .frame(width: 360, height: 360)
                .blur(radius: 110)
                .offset(x: 150, y: -190)
        }
        .ignoresSafeArea()
    }
}

struct MossSectionHeader: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color

    init(_ title: String, subtitle: String? = nil, symbol: String, tint: Color = MossTheme.accent) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct MossCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MossTheme.raisedSurface, in: RoundedRectangle(cornerRadius: MossTheme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: MossTheme.cornerRadius)
                    .strokeBorder(.white.opacity(0.08))
            }
    }
}

struct LessonRow: View {
    let info: BackendAPI.LessonInfo

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "graduationcap.fill")
                .font(.headline)
                .foregroundStyle(MossTheme.accent)
                .frame(width: 44, height: 44)
                .background(MossTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title ?? info.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                Text(secondaryLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if info.hasSummary {
                Image(systemName: "text.badge.star").font(.caption).foregroundStyle(MossTheme.assistant)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(15)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
    }

    private var durationLabel: String {
        let minutes = Int(info.durationSeconds) / 60
        let seconds = Int(info.durationSeconds) % 60
        return minutes > 0 ? "\(minutes) min" : "\(seconds) s"
    }

    private var secondaryLine: String {
        if info.title != nil {
            var parts = [info.startedAt.formatted(date: .abbreviated, time: .shortened), durationLabel]
            if let room = info.room, !room.isEmpty { parts.append("Raum \(room)") }
            return parts.joined(separator: " · ")
        }
        return "\(durationLabel) · \(info.segmentCount) segments"
    }
}
