import CoreGraphics
import Foundation
import Observation

/// What the reader knows about the text on the pages it is showing, and which
/// block the student has tapped.
///
/// The blocks come from the server, which read the book once with a
/// layout-aware OCR model. Nothing is recognised on the device: a scanned
/// schoolbook has no text layer to hit-test, and working the exercises out from
/// the numbering does not survive contact with real books — a line-number ruler
/// down the margin of a literary text counts exactly like a task list, a
/// running head numbered "1" is not Aufgabe 1, and a spread's list runs 8, 9 on
/// one page and 1 … 8 on the other. The model already knows which block is
/// which; the app just draws them.
@MainActor
@Observable
final class BookTaskStore {
    /// The blocks the student has tapped, in the order they were tapped —
    /// which is the order they go to Buch-KI, so "solve 3 and 5" arrives as
    /// 3 then 5. Tapping a picked block again puts it back.
    private(set) var selected: [BookPageTask] = []
    /// Whether the server has read this book yet — "none" means nobody has
    /// scanned it, which is not the same as a page with nothing on it.
    private(set) var scanStatus = "unknown"
    /// How far a running scan has got, 0…1.
    private(set) var scanFraction: Double?

    private var found: [Int: [BookPageTask]] = [:]
    private var loading: Set<Int> = []

    var isScanning: Bool { scanStatus == "scanning" }
    var isPartial: Bool { scanStatus == "partial" }
    var isUnavailable: Bool { scanStatus == "unavailable" }
    /// True once we know the server has nothing for this book.
    var needsScan: Bool { scanStatus == "none" }

    func tasks(onPages pages: [Int]) -> [BookPageTask] {
        pages.flatMap { found[$0] ?? [] }
    }

    func hasPendingPages(_ pages: [Int]) -> Bool {
        pages.contains { found[$0] == nil }
    }

    /// Fetch the regions of the pages now on screen, once each.
    func load(pages: [Int], bookID: String, pageBounds: [Int: CGRect], api: BackendAPI) async {
        let wanted = pages.filter { found[$0] == nil && !loading.contains($0) }
        guard !wanted.isEmpty else { return }
        loading.formUnion(wanted)
        defer { loading.subtract(wanted) }
        do {
            let response = try await api.bookRegions(id: bookID, pages: wanted)
            scanStatus = response.status
            scanFraction = response.fraction
            for page in wanted {
                guard response.isAvailable(page: page) else { continue }
                let bounds = pageBounds[page] ?? .zero
                found[page] = response.regions(onPage: page).enumerated().compactMap { index, region in
                    let rect = region.rect(in: bounds)
                    guard rect.isUsableTaskBounds else { return nil }
                    return BookPageTask(
                        pdfPage: page,
                        index: index,
                        label: region.label,
                        text: region.text,
                        bounds: rect
                    )
                }
            }
        } catch {
            // Offline, or the server is not reachable: reading the book still
            // works, there is just nothing to tap.
            scanStatus = "unavailable"
        }
    }

    /// A tap somewhere on a page: adds the block under the finger to the
    /// selection, or takes it out again if it was already in. Several can be
    /// held at once — one tap each — so a student can send "3, 4 and 5"
    /// together instead of three times over.
    ///
    /// When blocks overlap the smallest wins, so an exercise inside a list is
    /// picked rather than the list around it.
    func select(page: Int, at point: CGPoint) {
        let hits = (found[page] ?? []).filter { $0.bounds.contains(point) }
        guard let task = hits.min(by: { $0.bounds.area < $1.bounds.area }) else { return }
        toggle(task)
    }

    func toggle(_ task: BookPageTask) {
        if let index = selected.firstIndex(of: task) {
            selected.remove(at: index)
        } else {
            guard selected.count < Self.maxSelectionCount else { return }
            selected.append(task)
        }
    }

    func clearSelection() {
        selected.removeAll()
    }

    /// The panel is about the pages on screen, so anything picked on a page
    /// that has been turned away from is not picked any more.
    func dropSelectionOutside(_ pages: [Int]) {
        selected.removeAll { !pages.contains($0.pdfPage) }
    }

    /// Forget everything — after the book is re-scanned on the server.
    func reset() {
        found.removeAll()
        loading.removeAll()
        selected.removeAll()
        scanStatus = "unknown"
        scanFraction = nil
    }

    /// Keeps both the token row and the generated question bounded even if a
    /// scanned page contains hundreds of tiny OCR regions.
    private static let maxSelectionCount = 10
}

private extension CGRect {
    var area: CGFloat { width * height }

    var isUsableTaskBounds: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
            && width >= 1 && height >= 1
    }
}
