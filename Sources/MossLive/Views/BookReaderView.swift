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
        .background(InteractivePopGestureDisabler())
        // The editor role keeps the back control compact from its first frame.
        // Without it, iPadOS briefly lays out the previous screen's title and
        // then collapses it to a chevron, which looks like a sideways jump.
        .toolbarRole(.editor)
        // Install the assistant control for the destination's full lifetime.
        // It now participates in the navigation push instead of popping into
        // place after the PDF loads, and the leading slot remains available
        // for iPadOS' back and collapsed-sidebar controls.
        // An emptied group is not the same as no group at all. iPadOS keeps
        // drawing the group's glass platter once its last control goes away —
        // the grey capsule left behind where the assistant button used to be —
        // and the button inside it stays alive underneath, so the double tap
        // meant to bring the control back hit that leftover instead and hid it
        // again. Emit no group at all when there is nothing to put in it.
        .toolbar {
            if isAIButtonVisible || model.settings.showBookRenaming {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isAIButtonVisible {
                        bookAIButton
                    }
                    if model.settings.showBookRenaming {
                        bookMenu
                    }
                }
            }
        }
        .background(
            HiddenAIButtonTapRestorer(
                isHidden: !isAIButtonVisible,
                buttonFrame: rememberedAIButtonFrame
            ) {
                withAnimation(assistantAnimation) {
                    model.settings.showBookAIButton = true
                }
            }
        )
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

    @State private var lastAITapTime: Date = .distantPast
    @State private var singleAITapWorkItem: DispatchWorkItem?
    @AppStorage("library.bookAIButtonFrame") private var storedAIButtonFrame = ""

    private var assistantAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.42)
    }

    private var isAIButtonVisible: Bool {
        model.settings.showBookAIButton
    }

    private var bookAIButton: some View {
        Button(action: handleAIButtonTap) {
            Label("Seite fragen", systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(askingBookAI ? "Seitenassistent schließen" : "Seite fragen")
        // Remember the spot the control occupies so the double tap that brings
        // it back can look for exactly that spot. `onGeometryChange` measures
        // without wrapping the button in anything, which leaves the toolbar's
        // native styling untouched.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            rememberAIButtonFrame(frame)
        }
    }

    /// A second tap has to land inside this window to read as a double tap.
    private static let aiDoubleTapWindow: TimeInterval = 0.3

    private func handleAIButtonTap() {
        let now = Date()
        guard now.timeIntervalSince(lastAITapTime) >= Self.aiDoubleTapWindow else {
            singleAITapWorkItem?.cancel()
            singleAITapWorkItem = nil
            lastAITapTime = .distantPast
            withAnimation(assistantAnimation) {
                askingBookAI = false
                model.settings.showBookAIButton = false
            }
            return
        }

        lastAITapTime = now
        let item = DispatchWorkItem {
            singleAITapWorkItem = nil
            lastAITapTime = .distantPast
            guard isAIButtonVisible else { return }
            if !askingBookAI {
                bookAIDetent = .medium
            }
            withAnimation(assistantAnimation) {
                askingBookAI.toggle()
            }
        }
        singleAITapWorkItem = item
        // Opening the assistant waits for the double-tap window to close, so
        // the second tap of a real double tap always arrives first. The two
        // used to be timed independently, which let a slightly slow double tap
        // open the assistant over the button and lose the tap that follows.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.aiDoubleTapWindow + 0.02, execute: item)
    }

    /// Where the control last sat, in window coordinates. Persisted because the
    /// hidden state outlives the app: a reader opened with the control already
    /// hidden has nothing to measure, but still has to be restorable.
    private var rememberedAIButtonFrame: CGRect {
        let parts = storedAIButtonFrame.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return .zero }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func rememberAIButtonFrame(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let encoded = "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"
        if encoded != storedAIButtonFrame {
            storedAIButtonFrame = encoded
        }
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

    private func go(toIndex index: Int) {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        let clamped = min(max(index, 0), document.pageCount - 1)
        pdfView.goToPageAtFinalQuality(clamped)
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

        /// The student turns pages across the entire spread. Exiting the book
        /// back to the library is reserved exclusively for the navigation bar back button.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let swipe = gestureRecognizer as? PageSwipeGestureRecognizer,
                  let view = swipe.view as? BookPDFView
            else { return true }
            guard !view.regionControlsContain(swipe.startPoint) else { return false }
            return true
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
    // scrolling underneath the rectangle. It also has no recognizer that could
    // be asked to run alongside the back swipe — a pan added here once did,
    // and answering "yes" to every other recognizer is what let a drag out of
    // a region box slide back to the shelf.
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

/// Keeps the interactive pop gesture switched off for as long as the reader is
/// on screen, so that no drag across the book — turning a page, or pulling out
/// a region box — can slide back to the shelf. A book is left through the
/// navigation bar's back button and nothing else.
///
/// Switching the recognizer off once, when the reader appears, is not enough:
/// the navigation stack switches it back on whenever it updates, which is why
/// the swipe kept coming back. The reader re-asserts the state on every layout
/// pass and every SwiftUI update, and watches the recognizer on top of that,
/// then hands back whatever it found when the book closes. Replacing the
/// recognizer's delegate — the previous attempt — is not an option: it belongs
/// to the navigation stack, which both overwrites it and needs it back
/// afterwards for every other screen's swipe.
private struct InteractivePopGestureDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> PopGestureDisablingView {
        PopGestureDisablingView()
    }

    func updateUIView(_ uiView: PopGestureDisablingView, context: Context) {
        uiView.enforceDisabled()
    }
}

private final class PopGestureDisablingView: UIView {
    private weak var navigationController: UINavigationController?
    private var observation: NSKeyValueObservation?
    private var enabledBeforeReader: Bool?
    /// Set while this view is the one writing `isEnabled`, so the observer does
    /// not answer its own change.
    private var isAsserting = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            restore()
        } else {
            attach()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        enforceDisabled()
    }

    func enforceDisabled() {
        guard let recognizer = navigationController?.interactivePopGestureRecognizer,
              recognizer.isEnabled
        else { return }
        isAsserting = true
        recognizer.isEnabled = false
        isAsserting = false
    }

    private func attach() {
        guard navigationController == nil,
              let nav = enclosingNavigationController(),
              let recognizer = nav.interactivePopGestureRecognizer
        else { return }
        navigationController = nav
        enabledBeforeReader = recognizer.isEnabled
        observation = recognizer.observe(\.isEnabled, options: [.new]) { [weak self] recognizer, change in
            guard let self, !isAsserting, change.newValue == true else { return }
            isAsserting = true
            recognizer.isEnabled = false
            isAsserting = false
        }
        enforceDisabled()
    }

    private func restore() {
        observation = nil
        if let enabledBeforeReader {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = enabledBeforeReader
        }
        enabledBeforeReader = nil
        navigationController = nil
    }

    private func enclosingNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let nav = next as? UINavigationController {
                return nav
            }
            if let controller = next as? UIViewController, let nav = controller.navigationController {
                return nav
            }
            responder = next
        }
        return nil
    }

    deinit {
        restore()
    }
}

/// Brings the assistant control back when the student double-taps the spot it
/// used to sit in. While hidden the control is gone from the toolbar entirely —
/// that is what keeps the bar free of any leftover platter — so there is
/// nothing left to tap and the gesture has to be picked up from the window and
/// matched against the frame the button was last measured at.
private struct HiddenAIButtonTapRestorer: UIViewRepresentable {
    let isHidden: Bool
    let buttonFrame: CGRect
    let onRestore: () -> Void

    func makeUIView(context: Context) -> RestoringView {
        let view = RestoringView()
        view.isUserInteractionEnabled = false
        view.isRestoring = isHidden
        view.buttonFrame = buttonFrame
        view.onRestore = onRestore
        return view
    }

    func updateUIView(_ uiView: RestoringView, context: Context) {
        uiView.isRestoring = isHidden
        uiView.buttonFrame = buttonFrame
        uiView.onRestore = onRestore
        uiView.attachIfNeeded()
    }

    final class RestoringView: UIView, UIGestureRecognizerDelegate {
        var isRestoring = false {
            didSet {
                guard isRestoring != oldValue else { return }
                armedAt = isRestoring ? Date() : nil
            }
        }

        var buttonFrame: CGRect = .zero
        var onRestore: () -> Void = {}
        private weak var recognizer: UITapGestureRecognizer?
        private var armedAt: Date?

        /// How far outside the remembered frame a tap still counts. The control
        /// is a small circle in the corner, and the finger that put it away is
        /// not going to come back to the same pixel.
        private static let tapSlop: CGFloat = 22
        /// The trailing end of the navigation bar, where the control lives.
        private static let cornerWidth: CGFloat = 180
        private static let cornerHeight: CGFloat = 120
        /// The two taps that put the control away land on the window as well,
        /// and arrive there after the control is already gone — so without a
        /// pause they read as "bring it back" and the control never stays
        /// hidden. Start listening once the gesture that hid it is over.
        private static let armingDelay: TimeInterval = 0.6

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard recognizer == nil, let window else { return }
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.numberOfTouchesRequired = 1
            doubleTap.delegate = self
            doubleTap.cancelsTouchesInView = false
            doubleTap.delaysTouchesEnded = false
            window.addGestureRecognizer(doubleTap)
            recognizer = doubleTap
        }

        deinit {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }

        @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard isRestoring, let window, let armedAt,
                  Date().timeIntervalSince(armedAt) >= Self.armingDelay
            else { return }
            guard target(in: window).contains(gesture.location(in: window)) else { return }
            onRestore()
        }

        /// The control always sits at the trailing end of the navigation bar,
        /// so that corner is accepted whether or not anything was measured —
        /// a reader opened with the control already hidden never gets to
        /// measure it, and must still be restorable. A measured frame only
        /// widens the area to wherever the control actually was.
        private func target(in window: UIWindow) -> CGRect {
            let corner = CGRect(
                x: window.bounds.maxX - Self.cornerWidth,
                y: 0,
                width: Self.cornerWidth,
                height: Self.cornerHeight
            )
            guard buttonFrame.width > 0, buttonFrame.height > 0 else { return corner }
            let measured = buttonFrame.insetBy(dx: -Self.tapSlop, dy: -Self.tapSlop)
            // A toolbar item is measured in the bar's own hosting context, so
            // treat anything that did not come back in the top trailing corner
            // as unusable rather than stretching the target across the screen.
            guard measured.midX > window.bounds.midX, measured.minY < Self.cornerHeight else { return corner }
            return corner.union(measured)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
