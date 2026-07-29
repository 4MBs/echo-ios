import SwiftUI

/// The proportions the folder is drawn from. Shared, because the fold has to
/// land exactly on the body's top edge or the tab stops reading as a tab.
enum FolderGeometry {
    static let tabHeight: CGFloat = 18
    /// How far across the top edge the tab begins.
    static let tabStart: CGFloat = 0.50
    /// The rise of the fold between the body's top edge and the tab's.
    static let slant: CGFloat = 13
    static let corner: CGFloat = 18
    /// The tab's own corners, which are tighter than the body's.
    static let tabCorner: CGFloat = 8
}

/// The folder outline: a body, and a tab lifted off its top-right.
///
/// A real folder silhouette rather than a rounded rectangle with a folder glyph
/// inside it: the tab is what makes a grid of coloured cards read as *places
/// things are kept* at a glance, and the subject's own colour then does the
/// finding.
struct FolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tab = FolderGeometry.tabHeight
        let slant = FolderGeometry.slant
        let corner = FolderGeometry.corner
        let nib = FolderGeometry.tabCorner
        let width = rect.width
        let height = rect.height
        let fold = width * FolderGeometry.tabStart

        var path = Path()
        path.move(to: CGPoint(x: 0, y: tab + corner))
        path.addQuadCurve(to: CGPoint(x: corner, y: tab), control: CGPoint(x: 0, y: tab))
        path.addLine(to: CGPoint(x: fold, y: tab))
        path.addLine(to: CGPoint(x: fold + slant, y: nib))
        path.addQuadCurve(
            to: CGPoint(x: fold + slant + nib, y: 0),
            control: CGPoint(x: fold + slant, y: 0)
        )
        path.addLine(to: CGPoint(x: width - corner, y: 0))
        path.addQuadCurve(to: CGPoint(x: width, y: corner), control: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: height - corner))
        path.addQuadCurve(
            to: CGPoint(x: width - corner, y: height),
            control: CGPoint(x: width, y: height)
        )
        path.addLine(to: CGPoint(x: corner, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - corner), control: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}

/// The fold: the body's top edge and the rise onto the tab, drawn in the page's
/// own colour so the tab reads as a second sheet behind the front one. Without
/// it the silhouette is a single flat card with a bite taken out of the corner.
struct FolderCrease: Shape {
    func path(in rect: CGRect) -> Path {
        let tab = FolderGeometry.tabHeight
        let fold = rect.width * FolderGeometry.tabStart

        var path = Path()
        path.move(to: CGPoint(x: FolderGeometry.corner, y: tab))
        path.addLine(to: CGPoint(x: fold, y: tab))
        path.addLine(to: CGPoint(x: fold + FolderGeometry.slant, y: FolderGeometry.tabCorner))
        return path
    }
}

/// One subject folder: its colour, its icon, its name and how much is in it.
struct SubjectFolderTile: View {
    let name: String
    let count: Int
    let style: SubjectStyle

    var body: some View {
        ZStack(alignment: .topLeading) {
            FolderShape()
                .fill(
                    LinearGradient(
                        colors: [style.color.opacity(0.36), style.color.opacity(0.60)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            FolderCrease()
                .stroke(
                    Color(.systemGroupedBackground),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                )
            label
        }
        // Nothing in it, and it says so before it is tapped. Saturation rather
        // than opacity, so the name stays as readable as its neighbours' — this
        // folder is not less important, it is only empty.
        .saturation(count == 0 ? 0.16 : 1)
        .aspectRatio(1.04, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(countLabel)")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: style.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(style.tint.ink)
                .frame(height: 28, alignment: .leading)
            Spacer(minLength: 10)
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
            Text(countLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, FolderGeometry.tabHeight + 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// An empty folder says so rather than showing a nought: a subject you have
    /// not recorded yet is the normal state, not a count worth reading.
    private var countLabel: String {
        switch count {
        case 0: "Keine Aufnahmen"
        case 1: "1 Aufnahme"
        default: "\(count) Aufnahmen"
        }
    }
}

#Preview {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20)], spacing: 22) {
            ForEach(["Mathematik", "Biologie", "Wirtschaft/Politik", "Latein (2. FS)", "Sonstige"], id: \.self) {
                SubjectFolderTile(name: $0, count: $0 == "Biologie" ? 0 : 3, style: subjectStyle(for: $0))
            }
        }
        .padding(24)
    }
    .groupedScreen()
}
