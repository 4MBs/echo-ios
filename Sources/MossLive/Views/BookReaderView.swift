import PDFKit
import SwiftUI

/// One book, presented like the web reader the schoolbooks come from: a page —
/// or a spread — fills the screen, you flick sideways to turn, and a bottom bar
/// carries page navigation plus the one-page / two-page switcher. The first
/// open downloads the PDF from the server once; after that the persistent
/// on-device copy opens instantly.
struct BookReaderView: View {
    let api: BackendAPI
    let book: BackendAPI.Book

    private enum Phase {
        case downloading(Double)
        case ready(URL)
        case failed(Error)
    }

    @State private var phase: Phase?

    var body: some View {
        Group {
            switch phase {
            case .none, .downloading:
                downloadProgress
            case .ready(let url):
                PDFReader(url: url, book: book)
            case .failed(let error):
                ErrorState(error) { await open() }
                    .groupedScreen()
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await open() }
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
        if let cached = BackendAPI.cachedBook(id: book.id) {
            phase = .ready(cached)
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
        } catch {
            phase = .failed(error)
        }
    }
}

/// The reader itself: a PDFKit page view with the control bar underneath, and
/// — while a book is open — Buch-KI beside it.
private struct PDFReader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    let url: URL
    let book: BackendAPI.Book

    /// Printed page number minus PDF page number. Schoolbooks put a cover and
    /// often a few unnumbered pages in front, so the two rarely line up — and
    /// the shift differs per book, which is why it is stored per book.
    @AppStorage private var pageOffset: Int

    init(url: URL, book: BackendAPI.Book) {
        self.url = url
        self.book = book
        _pageOffset = AppStorage(wrappedValue: 0, "reader.pageOffset.\(book.id)")
    }

    @State private var document: PDFDocument?
    @State private var twoUp = true
    @State private var currentPage = 1
    @State private var visiblePages: [Int] = [1]
    @State private var pageCount = 0
    @State private var proxy = PDFViewProxy()
    @State private var bookAI = BookAIStore()
    @State private var tasks = BookTaskStore()
    @State private var askingBookAI = false
    @State private var askingForPage = false
    @State private var typedPage = ""
    @State private var openedAt = "1"
    @State private var adjustingNumbering = false
    @State private var typedNumbering = ""
    @State private var numberingPage = 1
    @State private var numberingPlaceholder = "1"
    @FocusState private var pageFieldFocused: Bool
    @FocusState private var numberingFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            reader
            if showsSidePanel {
                Divider().ignoresSafeArea(edges: .bottom)
                bookAIPanel(close: { askingBookAI = false })
                    .frame(width: 380)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.smooth(duration: 0.25), value: showsSidePanel)
        // Parsing a 300 MB schoolbook off the main thread keeps the push
        // animation smooth, and reusing the document means flipping the layout
        // does not re-read the file.
        .task(id: url) {
            document = await Task.detached(priority: .userInitiated) {
                LoadedDocument(document: PDFDocument(url: url))
            }.value.document
        }
        // Ask the server where the text sits on whatever is on screen, then
        // mark it. Both halves of a spread, and only once per page — the
        // answer is cached for as long as the book is open.
        .task(id: pagesKey) {
            let store = tasks
            proxy.onPageTap = { page, point in
                Task { @MainActor in store.select(page: page, at: point) }
            }
            guard let document else { return }
            store.dropSelectionOutside(visiblePages)
            // Anything already known about these pages shows at once; only the
            // fetch is deferred.
            markTasks()
            // Flicking through a chapter must not fire a request per page it
            // passes: the next turn cancels this task before the sleep is over.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            repeat {
                await store.load(
                    pages: visiblePages,
                    bookID: book.id,
                    pageBounds: pageBounds(of: document, pages: visiblePages),
                    api: api
                )
                markTasks()
                // If these pages are still being scanned, let their markers
                // appear without requiring the student to turn away and back.
                guard store.isScanning, store.hasPendingPages(visiblePages) else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: tasks.selected) { was, now in
            markTasks()
            // Tapping the first block is the whole request: the panel comes out
            // with it already picked, so the only thing left to do is send.
            // Picking a second one must not yank it open again.
            if was.isEmpty, !now.isEmpty { askingBookAI = true }
        }
        .onDisappear { proxy.clearTasks() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { bookAIButton }
            if model.settings.showPageNumberEditor {
                ToolbarItem(placement: .topBarTrailing) { readerMenu }
            }
        }
        // No room for both on a phone, so there the panel is a sheet — left at
        // half height, where the top of the page is still in view behind it.
        .sheet(isPresented: sheetPresented) {
            bookAIPanel(close: nil)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    private var reader: some View {
        Group {
            if let document {
                PDFKitView(
                    document: document,
                    twoUp: twoUp,
                    proxy: proxy,
                    currentPage: $currentPage,
                    visiblePages: $visiblePages,
                    pageCount: $pageCount
                )
                // Switching layout needs a freshly built PDFView: PDFKit does not
                // relayout an existing one when displayMode changes.
                .id(twoUp)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { controlBar }
    }

    // MARK: - Buch-KI

    /// Only ever here, inside an open book: the question Buch-KI answers is
    /// "this page", which the shelf outside has no answer for.
    private var bookAIButton: some View {
        Button {
            askingBookAI.toggle()
        } label: {
            Label("Buch-KI", systemImage: "sparkles")
        }
        // No explicit button style: a toolbar item already gets the system's
        // own treatment, and dressing it up again is what made this read as a
        // custom control sitting in an Apple navigation bar.
        .accessibilityLabel(askingBookAI ? "Buch-KI schließen" : "Buch-KI öffnen")
    }

    /// A regular width (iPad, and a phone in landscape) keeps the panel beside
    /// the book so the page stays readable while the answer is read.
    private var showsSidePanel: Bool {
        askingBookAI && sizeClass == .regular
    }

    private var sheetPresented: Binding<Bool> {
        Binding(
            get: { askingBookAI && sizeClass != .regular },
            set: { askingBookAI = $0 }
        )
    }

    private func bookAIPanel(close: (() -> Void)?) -> some View {
        BookAIPanel(
            bookID: book.id,
            numbering: numbering,
            visiblePages: visiblePages,
            store: bookAI,
            selectedTasks: tasks.selected,
            tapHint: tapHint,
            unpick: { tasks.toggle($0) },
            clearTasks: { tasks.clearSelection() },
            goToPage: { page in
                proxy.go(toPage: page)
                // On a phone the sheet covers the page it just turned to.
                if sizeClass != .regular { askingBookAI = false }
            },
            close: close
        )
    }

    /// Identity for the detection task: the pages on screen, plus whether the
    /// document has finished parsing (the first spread is visible before it
    /// has, and would otherwise never be read).
    private var pagesKey: String {
        "\(visiblePages)-\(document == nil)"
    }

    private func markTasks() {
        proxy.showTasks(tasks.tasks(onPages: visiblePages), selected: tasks.selected)
    }

    /// Each visible page's own size, so the server's fractions can be turned
    /// into rectangles. Pages of one book are not always the same shape.
    private func pageBounds(of document: PDFDocument, pages: [Int]) -> [Int: CGRect] {
        var bounds: [Int: CGRect] = [:]
        for number in pages {
            if let page = document.page(at: number - 1) {
                bounds[number] = page.bounds(for: .cropBox)
            }
        }
        return bounds
    }

    /// What the panel says about tapping. A book the server has not read yet
    /// has nothing to tap, and that is worth saying — otherwise the page just
    /// looks like it has no exercises on it.
    private var tapHint: String {
        if tasks.isScanning {
            let percent = Int((tasks.scanFraction ?? 0) * 100)
            return "Der Server liest dieses Buch gerade ein (\(percent) %). Danach kannst du "
                + "Aufgaben direkt antippen."
        }
        if tasks.needsScan {
            return "Dieses Buch wurde auf dem Server noch nicht eingelesen — tippbare Aufgaben "
                + "gibt es erst danach. Frag solange hier."
        }
        if tasks.isPartial {
            return "Das Buch ist nur teilweise eingelesen. Bereits fertige Seiten kannst du antippen; "
                + "auf den übrigen Seiten kannst du weiterhin eine Frage schreiben."
        }
        if tasks.isUnavailable {
            return "Die Markierungen sind gerade nicht erreichbar. Du kannst trotzdem eine Frage zu dieser Seite "
                + "schreiben."
        }
        return "Tippe im Buch direkt auf eine Aufgabe. Mehrere nacheinander antippen geht auch — "
            + "nochmal tippen hebt sie wieder auf."
    }

    /// The reader talks to the same server the rest of the app does.
    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    /// Set once per book and then forgotten, so it belongs in the navigation
    /// bar's overflow menu rather than anywhere near the reading controls — and
    /// can be taken off the screen entirely from Einstellungen once every book
    /// has been lined up.
    private var readerMenu: some View {
        Menu {
            Button {
                numberingPage = currentPage
                numberingPlaceholder = printedLabel(currentPage)
                typedNumbering = ""
                adjustingNumbering = true
            } label: {
                Label("Seitenzahlen anpassen…", systemImage: "textformat.123")
            }

            if pageOffset != 0 {
                Button(role: .destructive) {
                    pageOffset = 0
                } label: {
                    Label("Nummerierung zurücksetzen", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .popover(isPresented: $adjustingNumbering) { numberingEditor }
    }

    /// Teach the reader where the printed numbering starts: turn to a page whose
    /// number you can see, type that number, and every other page follows. The
    /// PDF page it is anchored to is captured on opening, so the book can be
    /// left where it is while the number is typed.
    private var numberingEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seitenzahlen")
                .font(.headline)

            Text("Welche Zahl steht auf dieser Seite? Das Buch richtet seine Nummerierung danach aus.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                TextField(numberingPlaceholder, text: $typedNumbering)
                    .keyboardType(.numberPad)
                    .focused($numberingFocused)
                    .multilineTextAlignment(.center)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(width: 76)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Gedruckte Seitenzahl")

                Text("= PDF-Seite \(numberingPage)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if pageOffset != 0 {
                Button("Zurücksetzen") {
                    pageOffset = 0
                    typedNumbering = ""
                }
                .font(.subheadline)
            }
        }
        .frame(width: 296, alignment: .leading)
        .padding(16)
        .presentationCompactAdaptation(.popover)
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            numberingFocused = true
        }
        .onChange(of: typedNumbering) { _, text in
            let digits = String(text.filter(\.isNumber).prefix(5))
            if digits != text { typedNumbering = digits }
            if let printed = Int(digits), printed >= 1 {
                pageOffset = printed - numberingPage
            }
        }
    }

    private var controlBar: some View {
        ZStack {
            pageControls
            HStack {
                modeToggle
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Previous/next buttons around the current page, which opens the jump-to
    /// field. A popover rather than a field sitting in the bar: one tap outside
    /// takes the keyboard, the caret and the popover away together, and there is
    /// no field left in the bar to tap a second time.
    private var pageControls: some View {
        HStack(spacing: 12) {
            Button {
                proxy.step(-1)
            } label: {
                Image(systemName: "arrow.left")
            }
            .disabled(currentPage <= 1)
            .accessibilityLabel("Vorherige Seite")

            pageIndicator

            Button {
                proxy.step(1)
            } label: {
                Image(systemName: "arrow.right")
            }
            .disabled(pageCount > 0 && currentPage >= pageCount)
            .accessibilityLabel("Nächste Seite")
        }
        .buttonStyle(.glass)
    }

    /// The current page, and the way to jump to another one.
    private var pageIndicator: some View {
        Button {
            typedPage = ""
            openedAt = printedLabel(currentPage)
            askingForPage = true
        } label: {
            // Fixed slots either side of the slash: the indicator stays put
            // whether the page number is 1 or 320 digits wide.
            HStack(spacing: 4) {
                Text(printedLabel(currentPage))
                    .frame(width: 36, alignment: .trailing)
                Text("/ \(printedLast)")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .leading)
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .accessibilityLabel("Seite \(printedLabel(currentPage)) von \(printedLast)")
        .popover(isPresented: $askingForPage) { pageJump }
    }

    /// Type a page and the book goes there — nothing to confirm. Deliberately
    /// shows no live page number, so nothing around the field redraws while the
    /// keyboard is up.
    private var pageJump: some View {
        HStack(spacing: 8) {
            TextField(openedAt, text: $typedPage)
                .keyboardType(.numberPad)
                .focused($pageFieldFocused)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(width: 76)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Seitennummer")

            Text("von \(printedLast)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
        // The popover has to finish presenting before it can take focus,
        // otherwise the keyboard occasionally never appears.
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            pageFieldFocused = true
        }
        .onChange(of: typedPage) { _, text in
            let digits = String(text.filter(\.isNumber).prefix(5))
            if digits != text { typedPage = digits }
            if let printed = Int(digits), let pdfPage = numbering.pdfPage(forPrinted: printed) {
                proxy.go(toPage: pdfPage)
            }
        }
    }

    /// The book's own numbering, shared with Buch-KI's panel so a cited page is
    /// named there exactly as the reader names it here.
    private var numbering: BookPageNumbering {
        BookPageNumbering(offset: pageOffset, pageCount: pageCount)
    }

    private func printedLabel(_ pdfPage: Int) -> String {
        numbering.printedLabel(pdfPage)
    }

    private var printedLast: Int {
        numbering.printedLast
    }

    /// A compact native menu keeps the toolbar quiet while making both layouts
    /// explicit when opened.
    private var modeToggle: some View {
        Menu {
            Picker("Seitendarstellung", selection: $twoUp) {
                Label("Einzelseite", systemImage: "rectangle.portrait")
                    .tag(false)
                Label("Doppelseite", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    .tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: twoUp ? "rectangle.portrait.on.rectangle.portrait" : "rectangle.portrait")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Seitendarstellung")
    }
}

/// Hands a freshly parsed document back from the loading task. PDFDocument is
/// not `Sendable`, but nothing touches this one until the reader owns it.
private struct LoadedDocument: @unchecked Sendable {
    let document: PDFDocument?
}

/// Bridge so the SwiftUI control bar can drive the UIKit PDFView (which only
/// exists once makeUIView has run).
private final class PDFViewProxy {
    weak var pdfView: PDFView?
    /// A tap that landed on a page: (PDF page number, point in that page's own
    /// coordinates). The reader turns it into a task.
    var onPageTap: ((Int, CGPoint) -> Void)?
    private var overlays: [String: PDFAnnotation] = [:]

    /// Mark the text blocks on the visible pages. Unpicked ones are faint
    /// enough to read straight through and just visible enough to look
    /// tappable; picked ones are filled and outlined in the tint, so several
    /// held at once read as a set rather than as one highlight among many.
    func showTasks(_ tasks: [BookPageTask], selected: [BookPageTask]) {
        guard let document = pdfView?.document else { return }
        let wanted = Set(tasks.map(\.id))
        for id in Array(overlays.keys) where !wanted.contains(id) {
            removeOverlay(id: id)
        }

        let picked = Set(selected)
        for task in tasks {
            guard task.pdfPage >= 1, task.pdfPage <= document.pageCount,
                  task.bounds.hasFinitePositiveArea,
                  let page = document.page(at: task.pdfPage - 1) else { continue }
            let annotation: PDFAnnotation
            if let existing = overlays[task.id] {
                annotation = existing
                annotation.bounds = task.bounds
            } else {
                annotation = PDFAnnotation(bounds: task.bounds, forType: .square, withProperties: nil)
                annotation.border = PDFBorder()
                annotation.isReadOnly = true
                page.addAnnotation(annotation)
                overlays[task.id] = annotation
            }
            style(annotation, selected: picked.contains(task))
        }
    }

    func clearTasks() {
        for id in Array(overlays.keys) {
            removeOverlay(id: id)
        }
    }

    private func style(_ annotation: PDFAnnotation, selected: Bool) {
        annotation.color = selected ? UIColor.tintColor.withAlphaComponent(0.9) : .clear
        annotation.interiorColor = UIColor.tintColor.withAlphaComponent(selected ? 0.24 : 0.07)
        annotation.border?.lineWidth = selected ? 2 : 0
    }

    private func removeOverlay(id: String) {
        guard let annotation = overlays.removeValue(forKey: id) else { return }
        annotation.page?.removeAnnotation(annotation)
    }

    /// One page forward or back. `goToNextPage(_:)` is unreliable outside the
    /// page-view-controller mode, so the target page is computed by hand — in a
    /// two-page spread that means stepping past the whole spread.
    func step(_ delta: Int) {
        guard let pdfView, let document = pdfView.document else { return }
        let indices = pdfView.visiblePages.compactMap { document.validIndex(for: $0) }
        guard let first = indices.min(), let last = indices.max() else { return }
        let target = delta > 0 ? min(last + 1, document.pageCount - 1) : max(first - 1, 0)
        go(toIndex: target)
    }

    func go(toPage number: Int) {
        guard number >= 1 else { return }
        go(toIndex: number - 1)
    }

    private func go(toIndex index: Int) {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        let clamped = min(max(index, 0), document.pageCount - 1)
        if let page = document.page(at: clamped) { pdfView.go(to: page) }
    }
}

/// A swipe that remembers where the finger landed. UISwipeGestureRecognizer
/// only reports where the flick ended, which is no use for telling a page turn
/// apart from a back swipe that started at the screen edge.
private final class PageSwipeGestureRecognizer: UISwipeGestureRecognizer {
    private(set) var startX: CGFloat = .greatestFiniteMagnitude

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view {
            startX = touch.location(in: view).x
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        startX = .greatestFiniteMagnitude
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
private final class BookPDFView: PDFView {
    /// Breathing room left around the page at its smallest, in points.
    private let margin: CGFloat = 14
    /// The scale the page rests at: its natural size on this screen, and the
    /// point below which zooming out stops.
    private(set) var restingScale: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        applyScaleLimits()
    }

    func applyScaleLimits() {
        guard document != nil, bounds.width > 40, bounds.height > 40 else { return }
        let sizeToFit = scaleFactorForSizeToFit
        guard sizeToFit > 0, sizeToFit.isFinite else { return }

        // scaleFactorForSizeToFit fills the bounds; shrinking it by the same
        // ratio the margin takes out of the bounds insets the page by exactly
        // `margin` points, whatever shape the page happens to be.
        let inset = min(
            (bounds.width - 2 * margin) / bounds.width,
            (bounds.height - 2 * margin) / bounds.height
        )
        let fit = sizeToFit * inset
        guard fit > 0 else { return }

        // Follow the new fit when the reader is sitting at the old one (rotation,
        // layout switch, a differently sized page) rather than stranding the page
        // at a scale that no longer belongs to it.
        let restingAtFit = restingScale == 0 || abs(scaleFactor - restingScale) < 0.001
        minScaleFactor = fit
        maxScaleFactor = fit * 6
        if restingAtFit || scaleFactor < fit, abs(scaleFactor - fit) > 0.001 {
            scaleFactor = fit
        }
        restingScale = fit
    }
}

/// PDFKit wrapper. The non-continuous display modes are the only ones that show
/// a real book: exactly one page (or one 2–3 style spread) fills the screen and
/// nothing scrolls. They bring no page-turn gesture of their own, and the
/// page-view controller that would provide one forces single-page layout — so
/// the sideways flick is added here instead.
private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let twoUp: Bool
    let proxy: PDFViewProxy
    @Binding var currentPage: Int
    /// Every PDF page on screen: one, or both halves of a spread. Buch-KI asks
    /// about exactly these.
    @Binding var visiblePages: [Int]
    @Binding var pageCount: Int

    func makeUIView(context: Context) -> PDFView {
        let pdfView = BookPDFView()
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
        proxy.pdfView = view
        context.coordinator.onPageChange = { updatePageState($0) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func updatePageState(_ view: PDFView) {
        guard let document = view.document else { return }
        // A page of a different size needs its own floor, so re-fit on arrival.
        (view as? BookPDFView)?.applyScaleLimits()
        pageCount = document.pageCount
        let visible = view.visiblePages.compactMap { page in
            document.validIndex(for: page).map { $0 + 1 }
        }.sorted()
        if let first = visible.first {
            currentPage = first
            visiblePages = visible
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPageChange: ((PDFView) -> Void)?
        var proxy: PDFViewProxy?
        private var observers: [NSObjectProtocol] = []

        func attach(to view: PDFView) {
            guard observers.isEmpty else { return }
            let names: [Notification.Name] = [.PDFViewPageChanged, .PDFViewVisiblePagesChanged, .PDFViewDocumentChanged]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: view, queue: .main
                ) { [weak self, weak view] _ in
                    guard let self, let view else { return }
                    onPageChange?(view)
                })
            }

            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = PageSwipeGestureRecognizer(target: self, action: #selector(handleSwipe))
                swipe.direction = direction
                swipe.delegate = self
                swipe.cancelsTouchesInView = false
                view.addGestureRecognizer(swipe)
            }

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.delegate = self
            // PDFKit's own recognizers keep working: this one only reports
            // where the finger landed, it never swallows the touch.
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
        }

        func detach() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            onPageChange = nil
        }

        /// A tap on the page, reported in that page's own coordinates so the
        /// reader can look it up against the exercise boxes it knows about.
        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PDFView, let document = view.document else { return }
            let point = recognizer.location(in: view)
            guard let page = view.page(for: point, nearest: false),
                  let index = document.validIndex(for: page) else { return }
            proxy?.onPageTap?(index + 1, view.convert(point, to: page))
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
                  swipe.direction == .right else { return true }
            return swipe.startX > Self.edgeStrip
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
            detach()
        }
    }
}

private extension PDFDocument {
    func validIndex(for page: PDFPage) -> Int? {
        let index = index(for: page)
        guard index != NSNotFound, index >= 0, index < pageCount else { return nil }
        return index
    }
}

private extension CGRect {
    var hasFinitePositiveArea: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }
}
