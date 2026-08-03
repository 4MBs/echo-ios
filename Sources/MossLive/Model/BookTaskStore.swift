import CoreGraphics
import Observation
import PDFKit
import UIKit
import Vision

/// Finds the exercises on the page the reader is showing, so they can be
/// tapped instead of typed.
///
/// The books are scans — there is no selectable text in them to hit-test — so
/// the page is rendered and read with the system's on-device text recognition.
/// Nothing leaves the iPad: this is only about *where* a task is, and the AI
/// that solves it reads the real page on the server as before.
enum BookTaskDetector {
    /// Wide enough that ten-point body type is legible to the recogniser, and
    /// small enough that a page costs a fraction of a second.
    static let renderWidth: CGFloat = 1600

    /// The exercises on one page, or nothing when the page cannot be read.
    @MainActor
    static func tasks(onPage number: Int, of page: PDFPage) async -> [BookPageTask] {
        // A rotated page would put the rendered image and the page's own
        // coordinates at right angles, and every box would land somewhere else.
        // Schoolbook scans are upright; anything else simply gets no taps.
        guard page.rotation % 360 == 0 else { return [] }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 1, bounds.height > 1 else { return [] }
        guard let image = render(page, bounds: bounds) else { return [] }
        let lines = await recognise(CarriedImage(image: image))
        return BookTaskLayout.tasks(from: lines, pdfPage: number, pageBounds: bounds)
    }

    @MainActor
    private static func render(_ page: PDFPage, bounds: CGRect) -> CGImage? {
        let height = (bounds.height * (renderWidth / bounds.width)).rounded()
        guard height > 1 else { return nil }
        let size = CGSize(width: renderWidth, height: height)
        return page.thumbnail(of: size, for: .cropBox).cgImage
    }

    /// Text recognition off the main actor: a page takes long enough that
    /// running it inline would show up as a stutter while turning pages.
    private static func recognise(_ carried: CarriedImage) async -> [RecognisedLine] {
        await Task.detached(priority: .userInitiated) { () -> [RecognisedLine] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["de-DE", "en-US"]
            let handler = VNImageRequestHandler(cgImage: carried.image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { observation -> RecognisedLine? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                // Vision's boxes are already normalised with the origin at the
                // bottom left — the same convention PDFKit uses for a page.
                return RecognisedLine(text: text, box: observation.boundingBox)
            }
        }.value
    }

    /// A rendered page on its way to the recogniser. CGImage is immutable and
    /// this one is handed over, never shared.
    private struct CarriedImage: @unchecked Sendable {
        let image: CGImage
    }
}

/// What the reader knows about the exercises on the pages it is showing, and
/// which one the student has picked.
///
/// Detection is cached per PDF page: flipping back and forth through a chapter
/// must not re-read the same pages, and a book is only ever open one at a time.
@MainActor
@Observable
final class BookTaskStore {
    /// The exercise the student tapped, if any. Buch-KI's panel sends this.
    private(set) var selected: BookPageTask?

    private var found: [Int: [BookPageTask]] = [:]
    private var running: Set<Int> = []

    func tasks(onPages pages: [Int]) -> [BookPageTask] {
        pages.flatMap { found[$0] ?? [] }
    }

    /// Read the pages now on screen, if they have not been read already.
    func detect(pages: [Int], in document: PDFDocument) async {
        for number in pages where found[number] == nil && !running.contains(number) {
            guard let page = document.page(at: number - 1) else {
                found[number] = []
                continue
            }
            running.insert(number)
            found[number] = await BookTaskDetector.tasks(onPage: number, of: page)
            running.remove(number)
        }
    }

    /// A tap somewhere on a page: picks the task under the finger, and picking
    /// the one already picked puts it back.
    func select(page: Int, at point: CGPoint) {
        guard let task = (found[page] ?? []).first(where: { $0.bounds.contains(point) }) else { return }
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
}
