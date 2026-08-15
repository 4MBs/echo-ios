import Combine
import PDFKit
import SwiftUI

private let bookTitleCharacterLimit = 96

/// One book, presented like the web reader the schoolbooks come from: a page —
/// or a spread — fills the screen, you flick sideways to turn, and a bottom bar
/// carries page navigation plus the one-page / two-page switcher. The first
/// open downloads the PDF from the server once; after that the persistent
/// on-device copy opens instantly.
struct BookReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let api: BackendAPI
    let book: BackendAPI.Book
    let onBookAvailable: @MainActor () -> Void

    @AppStorage private var renamedTitle: String

    private enum Phase {
        case downloading(Double)
        case ready(URL)
        case failed(Error)
    }

    @State private var phase: Phase?
    @State private var askingBookAI = false
    @State private var bookAIDetent: PresentationDetent = .medium
    @State private var renamingBook = false
    @State private var typedBookTitle = ""

    init(
        api: BackendAPI,
        book: BackendAPI.Book,
        onBookAvailable: @escaping @MainActor () -> Void = {}
    ) {
        self.api = api
        self.book = book
        self.onBookAvailable = onBookAvailable
        _renamedTitle = AppStorage(wrappedValue: "", "library.bookTitle.\(book.id)")
    }

    var body: some View {
        // Keep the task attached to one concrete container. `Group` is
        // transparent, so swapping its child from the loading view to the PDF
        // can detach and restart `.task` — which puts an already opened book
        // back into the loading phase, in a loop.
        ZStack {
            switch phase {
            case .none, .downloading:
                downloadProgress
            case .ready(let url):
                PDFReader(
                    url: url,
                    book: book,
                    askingBookAI: $askingBookAI,
                    bookAIDetent: $bookAIDetent
                )
            case .failed(let error):
                ErrorState(error) { await open() }
                    .groupedScreen()
            }
        }
        .navigationTitle(displayedTitle)
        .navigationBarTitleDisplayMode(.inline)
        // The editor role keeps the back control compact from its first frame.
        // Without it, iPadOS briefly lays out the previous screen's title and
        // then collapses it to a chevron, which looks like a sideways jump.
        .toolbarRole(.editor)
        // Install the assistant control for the destination's full lifetime.
        // It now participates in the navigation push instead of popping into
        // place after the PDF loads, and the leading slot remains available
        // for iPadOS' back and collapsed-sidebar controls.
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                bookAIButton
                if model.settings.showBookRenaming {
                    bookMenu
                }
            }
        }
        .task(id: book.id) { await open() }
        .onChange(of: typedBookTitle) { _, title in
            let limited = String(title.prefix(bookTitleCharacterLimit))
            if limited != title { typedBookTitle = limited }
        }
        .alert("Buch umbenennen", isPresented: $renamingBook) {
            TextField("Buchname", text: $typedBookTitle)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern", action: saveBookTitle)
                .disabled(typedBookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Der Name darf höchstens \(bookTitleCharacterLimit) Zeichen lang sein.")
        }
    }

    private var displayedTitle: String {
        let custom = renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = custom.isEmpty ? book.title : custom
        guard source.count > bookTitleCharacterLimit else { return source }
        return String(source.prefix(bookTitleCharacterLimit - 1)) + "…"
    }

    private var assistantAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.42)
    }

    private var bookAIButton: some View {
        Button {
            if !askingBookAI {
                bookAIDetent = .medium
            }
            withAnimation(assistantAnimation) {
                askingBookAI.toggle()
            }
        } label: {
            Label("Seite fragen", systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(askingBookAI ? "Seitenassistent schließen" : "Seite fragen")
    }

    private var bookMenu: some View {
        Menu {
            Button(action: beginRenamingBook) {
                Label("Buch umbenennen…", systemImage: "pencil")
            }

            if !renamedTitle.isEmpty {
                Button(role: .destructive) {
                    renamedTitle = ""
                } label: {
                    Label("Originalnamen wiederherstellen", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Buchoptionen")
    }

    private func beginRenamingBook() {
        let source = renamedTitle.isEmpty ? book.title : renamedTitle
        typedBookTitle = String(source.prefix(bookTitleCharacterLimit))
        renamingBook = true
    }

    private func saveBookTitle() {
        renamedTitle = String(
            typedBookTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(bookTitleCharacterLimit)
        )
    }

    private var downloadProgress: some View {
        Group {
            if case .downloading(let fraction) = phase, fraction > 0 {
                ProgressView(value: fraction) {
                    Text("Buch wird geladen…")
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
                .frame(maxWidth: 320)
            } else {
                ProgressView("Buch wird geladen…")
            }
        }
        .groupedScreen()
    }

    private func open() async {
        // A navigation or layout pass can make this view appear again. Never
        // replace a live PDF with the loading screen when it is already open.
        if case .some(.ready) = phase { return }

        if let cached = BackendAPI.cachedBook(id: book.id) {
            phase = .ready(cached)
            onBookAvailable()
            return
        }
        phase = .downloading(0)
        do {
            let url = try await api.downloadBook(book) { fraction in
                Task { @MainActor in
                    if case .downloading = phase { phase = .downloading(fraction) }
                }
            }
            phase = .ready(url)
            onBookAvailable()
        } catch {
            askingBookAI = false
            phase = .failed(error)
        }
    }
}

/// Hands a freshly parsed document back from the loading task. PDFDocument is
/// not `Sendable`, but nothing touches this one until the reader owns it.
struct LoadedDocument: @unchecked Sendable {
    let document: PDFDocument?
}

/// Bridge so the SwiftUI control bar can drive the UIKit PDFView (which only
/// exists once makeUIView has run).
final class PDFViewProxy {
    weak var pdfView: BookPDFView?

    /// One page forward or back. `goToNextPage(_:)` is unreliable outside the
    /// page-view-controller mode, so the target page is computed by hand — in a
    /// two-page spread that means stepping past the whole spread.
    func step(_ delta: Int) {
        guard let pdfView, let document = pdfView.document else { return }
        let indices = pdfView.visiblePages.map { document.index(for: $0) }
        guard let first = indices.min(), let last = indices.max() else { return }
        go(toIndex: delta > 0 ? last + 1 : first - 1)
    }

    func go(toPage number: Int) {
        go(toIndex: number - 1)
    }

    func beginRegionSelection(onSelected: @escaping (BackendAPI.BookPageRegion) -> Void) {
        pdfView?.beginRegionSelection(onSelected: onSelected)
    }

    func cancelRegionSelection() {
        pdfView?.cancelRegionSelection()
    }

    func clearRegionSelection() {
        pdfView?.display(region: nil)
    }

    func prepareForAnimatedResize(duration: TimeInterval) {
        pdfView?.prepareForAnimatedResize(duration: duration)
    }

    private func go(toIndex index: Int) {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        let clamped = min(max(index, 0), document.pageCount - 1)
        pdfView.goToPageAtFinalQuality(clamped)
    }
}

/// Device-resolution page images used only while PDFKit prepares its tiled
/// backing store. This is deliberately not a thumbnail cache: every entry is
/// rendered at or above the largest dimension the page needs on the current
/// display, and the cache is bounded by decoded bitmap cost.
final class BookPageRenderCache {
    private let documentURL: URL?
    private let images = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var pending: [String: [(UIImage?) -> Void]] = [:]

    init(document: PDFDocument) {
        documentURL = document.documentURL
        images.totalCostLimit = 128 * 1024 * 1024
    }

    func image(pageIndex: Int, maxPixelDimension: Int) -> UIImage? {
        images.object(forKey: key(pageIndex: pageIndex, maxPixelDimension: maxPixelDimension) as NSString)
    }

    func prepare(
        pageIndices: Set<Int>,
        maxPixelDimension: Int,
        completion: @escaping () -> Void = {}
    ) {
        guard !pageIndices.isEmpty else {
            DispatchQueue.main.async(execute: completion)
            return
        }

        let group = DispatchGroup()
        for pageIndex in pageIndices {
            group.enter()
            prepare(pageIndex: pageIndex, maxPixelDimension: maxPixelDimension) { _ in
                group.leave()
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    private func prepare(
        pageIndex: Int,
        maxPixelDimension: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        let cacheKey = key(pageIndex: pageIndex, maxPixelDimension: maxPixelDimension)
        let renderDimension = pixelBucket(for: maxPixelDimension)
        if let image = images.object(forKey: cacheKey as NSString) {
            DispatchQueue.main.async { completion(image) }
            return
        }

        lock.lock()
        if pending[cacheKey] != nil {
            pending[cacheKey]?.append(completion)
            lock.unlock()
            return
        }
        pending[cacheKey] = [completion]
        lock.unlock()

        let documentURL = documentURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = documentURL.flatMap {
                Self.renderPage(at: $0, pageIndex: pageIndex, maxPixelDimension: renderDimension)
            }
            if let image {
                self?.images.setObject(
                    image,
                    forKey: cacheKey as NSString,
                    cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                )
            }

            self?.lock.lock()
            let callbacks = self?.pending.removeValue(forKey: cacheKey) ?? []
            self?.lock.unlock()
            DispatchQueue.main.async {
                callbacks.forEach { $0(image) }
            }
        }
    }

    private func key(pageIndex: Int, maxPixelDimension: Int) -> String {
        "\(pageIndex)-\(pixelBucket(for: maxPixelDimension))"
    }

    private func pixelBucket(for maxPixelDimension: Int) -> Int {
        max(256, Int(ceil(Double(maxPixelDimension) / 256)) * 256)
    }

    private static func renderPage(
        at url: URL,
        pageIndex: Int,
        maxPixelDimension: Int
    ) -> UIImage? {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: pageIndex + 1)
        else { return nil }

        let box = page.getBoxRect(.cropBox).standardized
        guard box.width > 0, box.height > 0 else { return nil }
        // /Rotate turns the sheet clockwise for display, so a quarter turn
        // trades the page's width for its height.
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let quarterTurned = rotation == 90 || rotation == 270
        let pageSize = quarterTurned
            ? CGSize(width: box.height, height: box.width)
            : box.size

        let maximum = CGFloat(max(256, maxPixelDimension))
        let scale = maximum / max(pageSize.width, pageSize.height)
        let width = max(1, Int(ceil(pageSize.width * scale)))
        let height = max(1, Int(ceil(pageSize.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(target)

        // The page is mapped onto the bitmap by hand. getDrawingTransform fits a
        // box into a rectangle but never enlarges it, so a page prepared for a
        // Retina screen came back at its printed point size — a postage stamp in
        // the middle of a white sheet, which is what the reader then showed
        // until a zoom threw the picture away.
        context.scaleBy(
            x: CGFloat(width) / pageSize.width,
            y: CGFloat(height) / pageSize.height
        )
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: pageSize.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: pageSize.width, y: pageSize.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: pageSize.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        guard let rendered = context.makeImage() else { return nil }
        return UIImage(cgImage: rendered)
    }
}

/// A swipe that remembers where the finger landed. UISwipeGestureRecognizer
/// only reports where the flick ended, which is no use for telling a page turn
/// apart from a back swipe that started at the screen edge.
final class PageSwipeGestureRecognizer: UISwipeGestureRecognizer {
    private(set) var startPoint = CGPoint(
        x: CGFloat.greatestFiniteMagnitude,
        y: CGFloat.greatestFiniteMagnitude
    )

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view {
            startPoint = touch.location(in: view)
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        startPoint = CGPoint(
            x: CGFloat.greatestFiniteMagnitude,
            y: CGFloat.greatestFiniteMagnitude
        )
    }
}

/// A PDFView that will not let the page shrink below its natural size on screen.
///
/// The floor is not a fixed number: it is derived from whatever is on screen
/// right now — the page's own dimensions, the current layout, the device
/// orientation — so every book, and every oddly sized page inside a book, gets
/// its own. The margin around the page is what stays constant, in points, so
/// the spread never sits edge to edge but never floats in the middle of the
/// screen either.
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let twoUp: Bool
    let proxy: PDFViewProxy
    @Binding var currentPage: Int
    /// Every PDF page on screen: one, or both halves of a spread. The assistant asks
    /// about exactly these.
    @Binding var visiblePages: [Int]
    @Binding var pageCount: Int
    @Binding var selectedRegion: BackendAPI.BookPageRegion?

    func makeUIView(context: Context) -> PDFView {
        let pdfView = BookPDFView(frame: .zero)
        proxy.pdfView = pdfView
        // PDFKit is order-sensitive: layout has to be configured before the
        // document is attached, or the direction quietly falls back to vertical.
        pdfView.displayDirection = .horizontal
        pdfView.displayMode = twoUp ? .twoUp : .singlePage
        pdfView.displaysAsBook = twoUp
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        // autoScales would overwrite the scale limits on every layout pass;
        // BookPDFView takes over the fitting instead.
        pdfView.autoScales = false
        pdfView.backgroundColor = .clear
        pdfView.document = document
        pdfView.onRegionChanged = { region in
            context.coordinator.record(region: region)
            selectedRegion = region
        }
        pdfView.display(region: selectedRegion)
        context.coordinator.record(region: selectedRegion)

        context.coordinator.proxy = proxy
        context.coordinator.onPageChange = { updatePageState($0) }
        context.coordinator.attach(to: pdfView)

        let restore = currentPage
        DispatchQueue.main.async {
            if let page = document.page(at: max(restore - 1, 0)) { pdfView.go(to: page) }
            updatePageState(pdfView)
        }
        return pdfView
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = { updatePageState($0) }
        guard let bookView = view as? BookPDFView else { return }
        bookView.setPageLayout(
            twoUp: twoUp,
            anchorPage: currentPage,
            animated: !UIAccessibility.isReduceMotionEnabled
        )
        bookView.onRegionChanged = { region in
            context.coordinator.record(region: region)
            selectedRegion = region
        }
        if context.coordinator.shouldDisplay(region: selectedRegion) {
            bookView.display(region: selectedRegion)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func updatePageState(_ view: PDFView) {
        guard let document = view.document else { return }
        // A page of a different size needs its own floor, so re-fit on arrival.
        (view as? BookPDFView)?.applyScaleLimits()
        if pageCount != document.pageCount {
            pageCount = document.pageCount
        }
        let visible = view.visiblePages.map { document.index(for: $0) + 1 }.sorted()
        if let first = visible.first {
            if currentPage != first { currentPage = first }
            if visiblePages != visible { visiblePages = visible }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPageChange: ((PDFView) -> Void)?
        var proxy: PDFViewProxy?
        private var observers: [NSObjectProtocol] = []
        private var pageUpdateScheduled = false
        private var lastRegion: BackendAPI.BookPageRegion?
        private var hasRegion = false

        func attach(to view: PDFView) {
            guard observers.isEmpty else { return }
            let names: [Notification.Name] = [.PDFViewPageChanged, .PDFViewVisiblePagesChanged, .PDFViewDocumentChanged]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: view, queue: .main
                ) { [weak self, weak view] _ in
                    guard let self, let view else { return }
                    schedulePageUpdate(for: view)
                })
            }

            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = PageSwipeGestureRecognizer(target: self, action: #selector(handleSwipe))
                swipe.direction = direction
                swipe.delegate = self
                swipe.cancelsTouchesInView = false
                view.addGestureRecognizer(swipe)
            }
        }

        func record(region: BackendAPI.BookPageRegion?) {
            lastRegion = region
            hasRegion = true
        }

        func shouldDisplay(region: BackendAPI.BookPageRegion?) -> Bool {
            guard !hasRegion || lastRegion != region else { return false }
            record(region: region)
            return true
        }

        private func schedulePageUpdate(for view: PDFView) {
            guard !pageUpdateScheduled else { return }
            pageUpdateScheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                pageUpdateScheduled = false
                guard let view else { return }
                onPageChange?(view)
            }
        }

        @objc private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard let view = recognizer.view as? BookPDFView else { return }
            // Once the reader has zoomed in, a sideways drag means "look at the
            // rest of this page", not "turn it".
            guard view.restingScale == 0 || view.scaleFactor <= view.restingScale * 1.05 else { return }
            proxy?.step(recognizer.direction == .left ? 1 : -1)
        }

        /// A backwards flick starting at the very left edge belongs to the
        /// navigation controller, so going back to the library still works.
        /// Everywhere else it turns the page.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let swipe = gestureRecognizer as? PageSwipeGestureRecognizer,
                  let view = swipe.view as? BookPDFView
            else { return true }
            guard !view.regionControlsContain(swipe.startPoint) else { return false }
            return swipe.direction != .right || swipe.startPoint.x > Self.edgeStrip
        }

        /// The PDF's own scroll view keeps its pan recognizer, and the flick has
        /// to run alongside it. Recognizers from outside the reader — the back
        /// swipe above all — must not: turning a page and leaving the book at
        /// the same time is how a swipe back used to end up in the library.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            belongsToReader(otherGestureRecognizer, alongside: gestureRecognizer)
        }

        /// Outside recognizers wait for the page turn to fail before they run.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            !belongsToReader(otherGestureRecognizer, alongside: gestureRecognizer)
        }

        private func belongsToReader(
            _ other: UIGestureRecognizer,
            alongside mine: UIGestureRecognizer
        ) -> Bool {
            guard let readerView = mine.view, let otherView = other.view else { return false }
            return otherView.isDescendant(of: readerView)
        }

        /// Width of the strip along the left edge reserved for the back swipe.
        private static let edgeStrip: CGFloat = 40

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// A temporary transparent drawing surface above PDFKit. It takes the gesture
/// while active, which prevents the PDF's scroll view from panning underneath
/// the student's rectangle, then removes itself as soon as the drag finishes.
final class BookRegionSelectionOverlay: UIView {
    var onFinished: ((CGRect) -> Void)?

    private let shape = CAShapeLayer()
    private var start = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Buchbereich markieren"
        accessibilityIdentifier = "Buchbereich markieren"
        shape.fillColor = UIColor.systemBlue.withAlphaComponent(0.14).cgColor
        shape.strokeColor = UIColor.systemBlue.cgColor
        shape.lineWidth = 2
        shape.lineDashPattern = [7, 5]
        layer.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Handle the drawing surface's touches directly. A pan recognizer here
    // still had to arbitrate with PDFKit's private scroll recognizers and could
    // lose the first drag after the assistant changed the reader's width. The
    // temporary overlay is the topmost interactive view while selection is
    // active, so direct touch tracking is deterministic and keeps PDFKit from
    // scrolling underneath the rectangle.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        start = point
        shape.path = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        shape.path = UIBezierPath(roundedRect: rectangle(to: point), cornerRadius: 6).cgPath
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        onFinished?(rectangle(to: point))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        shape.path = nil
    }

    private func rectangle(to point: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
    }
}

extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}
