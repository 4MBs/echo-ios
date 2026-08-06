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
    /// The block the student tapped. Buch-KI's panel sends this.
    private(set) var selected: BookPageTask?
    /// Whether the server has read this book yet — "none" means nobody has
    /// scanned it, which is not the same as a page with nothing on it.
    private(set) var scanStatus = "unknown"
    /// How far a running scan has got, 0…1.
    private(set) var scanFraction: Double?

    private var found: [Int: [BookPageTask]] = [:]
    private var loading: Set<Int> = []

    var isScanning: Bool { scanStatus == "scanning" }
    /// True once we know the server has nothing for this book.
    var needsScan: Bool { scanStatus == "none" }

    func tasks(onPages pages: [Int]) -> [BookPageTask] {
        pages.flatMap { found[$0] ?? [] }
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
                let bounds = pageBounds[page] ?? .zero
                found[page] = response.regions(onPage: page).enumerated().map { index, region in
                    BookPageTask(
                        pdfPage: page,
                        index: index,
                        label: region.label,
                        text: region.text,
                        bounds: region.rect(in: bounds)
                    )
                }
            }
        } catch {
            // Offline, or the server is not reachable: reading the book still
            // works, there is just nothing to tap.
            scanStatus = "unavailable"
        }
    }

    /// A tap somewhere on a page: picks the block under the finger, and picking
    /// the one already picked puts it back. When blocks overlap the smallest
    /// wins, so an exercise inside a list is preferred over the list.
    func select(page: Int, at point: CGPoint) {
        let hits = (found[page] ?? []).filter { $0.bounds.contains(point) }
        guard let task = hits.min(by: { $0.bounds.area < $1.bounds.area }) else { return }
        selected = task == selected ? nil : task
    }

    func clearSelection() {
        selected = nil
    }

    /// The panel is about the pages on screen, so a selection left behind on a
    /// page that has been turned away from is not a selection any more.
    func dropSelectionOutside(_ pages: [Int]) {
        if let task = selected, !pages.contains(task.pdfPage) {
            selected = nil
        }
    }

    /// Forget everything — after the book is re-scanned on the server.
    func reset() {
        found.removeAll()
        loading.removeAll()
        selected = nil
        scanStatus = "unknown"
        scanFraction = nil
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
