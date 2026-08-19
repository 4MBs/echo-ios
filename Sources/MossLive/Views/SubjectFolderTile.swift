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

private extension View {
    /// Take exactly `limit` lines of height whether or not the text fills them,
    /// or as many as the text needs when there is no limit.
    ///
    /// The reserving is the point. A tile sized from its own content is a tile
    /// whose size depends on how long a subject happens to be called, and a
    /// grid of those does not line up.
    @ViewBuilder
    func reservingLines(_ limit: Int?) -> some View {
        if let limit {
            lineLimit(limit, reservesSpace: true)
        } else {
            lineLimit(nil)
        }
    }
}

/// One subject folder: its colour, its icon, its name and how much is in it.
struct SubjectFolderTile: View {
    let name: String
    let count: Int
    let style: SubjectStyle

    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        folder
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), \(countLabel)")
    }

    /// The folder keeps its squarish proportion at normal text sizes, because a
    /// grid of equal cards is what makes it read as a shelf. At accessibility
    /// sizes it grows to whatever the name and the count need instead: the text
    /// scales the whole way rather than being capped or cropped by the tile.
    ///
    /// "Equal" is why `label` reserves its lines rather than merely limiting
    /// them. `aspectRatio(_:contentMode: .fit)` is handed a column width and no
    /// height, so it resolves the height from what is inside — and then scales
    /// the *width* to match. A name that wrapped onto a second line therefore
    /// made its whole folder bigger than its neighbours in both directions:
    /// Klassenleitungsstunde and Wirtschaft/Politik stood out of a shelf of
    /// Englisch and Spanisch. Reserved lines make that height the same for
    /// every subject, whatever it is called.
    @ViewBuilder private var folder: some View {
        if dynamicTypeSize.isAccessibilitySize {
            silhouette
        } else {
            silhouette.aspectRatio(1.04, contentMode: .fit)
        }
    }

    private var silhouette: some View {
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
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(style.icon)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(style.color)
                .frame(height: 28, alignment: .leading)
                .accessibilityHidden(true)
            Spacer(minLength: 10)
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
                // Two lines are the tile's budget while it holds its shape, and
                // it spends both whether or not the name needs them — a folder
                // may not be a different size from the one beside it. Once the
                // tile grows with the text, nothing has to be dropped at all.
                .reservingLines(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .accessibilityIdentifier("subject-folder-title-visual")
                .accessibilityHidden(true)
            Text(countLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
                // One reserved line: "Keine Aufnahmen" is the longest this ever
                // says, and it fits the narrowest column with the scale factor
                // to spare. Two would only add empty tile under every folder.
                .reservingLines(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
                .accessibilityIdentifier("subject-folder-count-visual")
                .accessibilityHidden(true)
        }
        .padding(.top, FolderGeometry.tabHeight + 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The tile itself already exposes one complete, localized label. Keep
        // its visual text out of the child accessibility tree so VoiceOver and
        // the system audit do not inspect cropped glyph snapshots separately.
        .accessibilityHidden(true)
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
