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
        // Keep the task attached to one concrete container. `Group` is
        // transparent, so swapping its child from the loading view to the PDF
        // can detach and restart `.task` — which puts an already opened book
        // back into the loading phase, in a loop.
        ZStack {
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
        .task(id: book.id) { await open() }
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
/// — while a book is open — "Seite fragen" beside it.
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
    @State private var askingBookAI = false
    @State private var bookAIDetent: PresentationDetent = .medium
    @State private var selectedRegion: BackendAPI.BookPageRegion?
    @State private var selectingRegion = false
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
        reader
            // Parsing a 300 MB schoolbook off the main thread keeps the push
            // animation smooth, and reusing the document means flipping the
            // layout does not re-read the file.
            .task(id: url) {
                document = await Task.detached(priority: .userInitiated) {
                    LoadedDocument(document: PDFDocument(url: url))
                }.value.document
            }
            .toolbar {
                if model.settings.showPageNumberEditor {
                    ToolbarItem(placement: .topBarTrailing) { readerMenu }
                }
            }
            // One adaptive presentation, not a hand-switched HStack and sheet.
            // SwiftUI keeps the panel as a trailing column on an iPad and adapts
            // it to a sheet in compact width, and — this is the part that
            // matters — it hosts it outside the navigation content.
            //
            // The panel is a NavigationStack, because that is what gives it a
            // real bar. Placed inline in an HStack it was a navigation stack
            // nested inside the pushed reader, which is unsupported: opening it
            // popped the whole stack back to the shelf and left the shelf's
            // route torn down behind it. An inspector is its own presentation,
            // so nothing behind it moves.
            .inspector(isPresented: $askingBookAI) {
                bookAIPanel
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
                    .presentationDetents([.medium, .large], selection: $bookAIDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
            .onChange(of: visiblePages) { _, pages in
                guard let selectedRegion, !pages.contains(selectedRegion.pdfPage) else { return }
                self.selectedRegion = nil
                proxy.clearRegionSelection()
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
                    pageCount: $pageCount,
                    selectedRegion: selectedRegion
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
        .overlay(alignment: .top) {
            if selectingRegion {
                regionSelectionBanner
                    .padding(.top, 12)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controlBar }
    }

    // MARK: - Seite fragen

    /// Only ever here, inside an open book: the assistant answers questions on
    /// "this page", which the shelf outside has no answer for.
    ///
    /// It sits in the control bar with the other things you do to a book, not
    /// alone in the top corner — the page arrows, the layout switch and this
    /// are one set of controls and belong within reach of the same thumb. The
    /// prominent style while open communicates the persistent state, but
    /// this remains a button semantically: its action is to present a panel,
    /// not to change a setting.
    @ViewBuilder private var bookAIButton: some View {
        if askingBookAI {
            Button(action: toggleBookAI) { bookAIButtonLabel }
                .buttonStyle(.glassProminent)
                .accessibilityLabel("Seite fragen schließen")
        } else {
            Button(action: toggleBookAI) { bookAIButtonLabel }
                .buttonStyle(.glass)
                .accessibilityLabel("Seite fragen")
        }
    }

    @ViewBuilder private var bookAIButtonLabel: some View {
        if sizeClass == .regular {
            Label("Seite fragen", systemImage: "sparkles")
        } else {
            Label("Seite fragen", systemImage: "sparkles")
                .labelStyle(.iconOnly)
        }
    }

    private func toggleBookAI() {
        bookAIDetent = .medium
        askingBookAI.toggle()
    }

    private var bookAIPanel: some View {
        BookAIPanel(
            bookID: book.id,
            bookTitle: book.title,
            numbering: numbering,
            visiblePages: visiblePages,
            region: selectedRegion,
            store: bookAI,
            detent: $bookAIDetent,
            goToPage: { page in
                proxy.go(toPage: page)
            },
            requestRegion: beginRegionSelection,
            clearRegion: clearRegionSelection,
            close: { askingBookAI = false }
        )
    }

    private var regionSelectionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
            Text("Ziehe einen Rahmen um den gewünschten Bereich.")
                .font(.subheadline.weight(.medium))
            Button("Abbrechen") {
                proxy.cancelRegionSelection()
                selectingRegion = false
            }
            .font(.subheadline)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(minHeight: 48)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func beginRegionSelection() {
        askingBookAI = false
        selectingRegion = true
        proxy.clearRegionSelection()
        selectedRegion = nil
        // Begin on the next run loop instead of guessing how long the adaptive
        // inspector's dismissal animation takes. The overlay follows the
        // reader's live bounds, so rotations and different sheet transitions
        // cannot leave it mapped to a stale size.
        DispatchQueue.main.async {
            proxy.beginRegionSelection { region in
                selectedRegion = region
                selectingRegion = false
                bookAIDetent = .medium
                askingBookAI = true
            }
        }
    }

    private func clearRegionSelection() {
        selectedRegion = nil
        selectingRegion = false
        proxy.cancelRegionSelection()
        proxy.clearRegionSelection()
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

    /// Everything you do to an open book, in one bar: the layout on the left,
    /// the page in the middle where it can stay centred whatever flanks it, and
    /// "Seite fragen" on the right.
    private var controlBar: some View {
        ZStack {
            pageControls
            HStack {
                modeToggle
                Spacer()
                bookAIButton
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

    /// The book's own numbering, shared with the assistant panel so a cited page is
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
    private let selectedRegionLayer = CAShapeLayer()
    private var selectionOverlay: BookRegionSelectionOverlay?
    private var displayedRegion: BackendAPI.BookPageRegion?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureRegionLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRegionLayer()
    }

    private func configureRegionLayer() {
        selectedRegionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.12).cgColor
        selectedRegionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectedRegionLayer.lineWidth = 2
        selectedRegionLayer.lineDashPattern = [7, 5]
        selectedRegionLayer.lineJoin = .round
        layer.addSublayer(selectedRegionLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyScaleLimits()
        selectionOverlay?.frame = bounds
        updateDisplayedRegion()
    }

    func beginRegionSelection(onSelected: @escaping (BackendAPI.BookPageRegion) -> Void) {
        cancelRegionSelection()
        let overlay = BookRegionSelectionOverlay(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onFinished = { [weak self] rect in
            guard let self else { return }
            if let region = normalizedRegion(from: rect) {
                display(region: region)
                onSelected(region)
                cancelRegionSelection()
            }
        }
        addSubview(overlay)
        selectionOverlay = overlay
    }

    func cancelRegionSelection() {
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
    }

    func display(region: BackendAPI.BookPageRegion?) {
        displayedRegion = region
        updateDisplayedRegion()
    }

    private func normalizedRegion(from selection: CGRect) -> BackendAPI.BookPageRegion? {
        guard selection.width >= 18, selection.height >= 18,
              let document,
              let page = page(for: CGPoint(x: selection.midX, y: selection.midY), nearest: true)
        else { return nil }

        let pageFrame = convert(page.bounds(for: .cropBox), from: page)
        let clipped = selection.standardized.intersection(pageFrame)
        guard !clipped.isNull, clipped.width >= 18, clipped.height >= 18 else { return nil }

        let pageBounds = page.bounds(for: .cropBox)
        let pdfRect = convert(clipped, to: page).intersection(pageBounds)
        let pageIndex = document.index(for: page)
        guard pageBounds.width > 0, pageBounds.height > 0, pageIndex >= 0 else { return nil }

        return BackendAPI.BookPageRegion(
            pdfPage: pageIndex + 1,
            x: Double((pdfRect.minX - pageBounds.minX) / pageBounds.width).clamped01,
            y: Double((pdfRect.minY - pageBounds.minY) / pageBounds.height).clamped01,
            width: Double(pdfRect.width / pageBounds.width).clamped01,
            height: Double(pdfRect.height / pageBounds.height).clamped01
        )
    }

    private func updateDisplayedRegion() {
        // PDFKit installs its page-hosting subviews after initialization. Move
        // the highlight to the end whenever it changes so it remains above the
        // rendered page instead of disappearing behind that host view.
        selectedRegionLayer.removeFromSuperlayer()
        layer.addSublayer(selectedRegionLayer)
        guard let region = displayedRegion,
              let document,
              let page = document.page(at: region.pdfPage - 1)
        else {
            selectedRegionLayer.path = nil
            return
        }
        let bounds = page.bounds(for: .cropBox)
        let pdfRect = CGRect(
            x: bounds.minX + bounds.width * CGFloat(region.x),
            y: bounds.minY + bounds.height * CGFloat(region.y),
            width: bounds.width * CGFloat(region.width),
            height: bounds.height * CGFloat(region.height)
        )
        selectedRegionLayer.path = UIBezierPath(roundedRect: convert(pdfRect, from: page), cornerRadius: 6).cgPath
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
    /// Every PDF page on screen: one, or both halves of a spread. The assistant asks
    /// about exactly these.
    @Binding var visiblePages: [Int]
    @Binding var pageCount: Int
    let selectedRegion: BackendAPI.BookPageRegion?

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
        pdfView.display(region: selectedRegion)

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
        (view as? BookPDFView)?.display(region: selectedRegion)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func updatePageState(_ view: PDFView) {
        guard let document = view.document else { return }
        // A page of a different size needs its own floor, so re-fit on arrival.
        (view as? BookPDFView)?.applyScaleLimits()
        pageCount = document.pageCount
        let visible = view.visiblePages.map { document.index(for: $0) + 1 }.sorted()
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
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// A temporary transparent drawing surface above PDFKit. It takes the gesture
/// while active, which prevents the PDF's scroll view from panning underneath
/// the student's rectangle, then removes itself as soon as the drag finishes.
private final class BookRegionSelectionOverlay: UIView {
    var onFinished: ((CGRect) -> Void)?

    private let shape = CAShapeLayer()
    private var start = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Buchbereich markieren"
        shape.fillColor = UIColor.systemBlue.withAlphaComponent(0.14).cgColor
        shape.strokeColor = UIColor.systemBlue.cgColor
        shape.lineWidth = 2
        shape.lineDashPattern = [7, 5]
        layer.addSublayer(shape)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            start = point
            shape.path = nil
        case .changed:
            shape.path = UIBezierPath(roundedRect: rectangle(to: point), cornerRadius: 6).cgPath
        case .ended:
            onFinished?(rectangle(to: point))
        case .cancelled, .failed:
            shape.path = nil
        default:
            break
        }
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

private extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}
