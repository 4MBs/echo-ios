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

/// The reader itself: a PDFKit page view with page controls underneath and
/// "Seite fragen" in the reader's stable navigation toolbar.
private struct PDFReader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let url: URL
    let book: BackendAPI.Book
    @Binding var askingBookAI: Bool
    @Binding var bookAIDetent: PresentationDetent

    /// Printed page number minus PDF page number. Schoolbooks put a cover and
    /// often a few unnumbered pages in front, so the two rarely line up — and
    /// the shift differs per book, which is why it is stored per book.
    @AppStorage private var pageOffset: Int

    init(
        url: URL,
        book: BackendAPI.Book,
        askingBookAI: Binding<Bool>,
        bookAIDetent: Binding<PresentationDetent>
    ) {
        self.url = url
        self.book = book
        _askingBookAI = askingBookAI
        _bookAIDetent = bookAIDetent
        _pageOffset = AppStorage(wrappedValue: 0, "reader.pageOffset.\(book.id)")
        _bookAI = State(initialValue: BookAIStore(bookID: book.id))
    }

    @State private var document: PDFDocument?
    @State private var twoUp = true
    @State private var currentPage = 1
    @State private var visiblePages: [Int] = [1]
    @State private var pageCount = 0
    @State private var proxy = PDFViewProxy()
    @State private var bookAI: BookAIStore
    @State private var selectedRegion: BackendAPI.BookPageRegion?
    @State private var selectingRegion = false
    @State private var askingForPage = false
    @State private var typedPage = ""
    @State private var adjustingNumbering = false
    @State private var typedNumbering = ""
    @State private var numberingPage = 1
    @State private var numberingPlaceholder = "1"
    @FocusState private var numberingFocused: Bool

    /// One transaction drives the panel and every part of the reader whose
    /// available width changes with it.
    private var assistantAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.42)
    }

    /// Dragging the compact sheet down comes back through this binding, so it
    /// uses the same transaction as taps on the toolbar button.
    private var assistantPresentation: Binding<Bool> {
        Binding(
            get: { askingBookAI },
            set: { presented in
                withAnimation(assistantAnimation) {
                    askingBookAI = presented
                }
            }
        )
    }

    var body: some View {
        adaptiveReader
            // Parsing a 300 MB schoolbook off the main thread keeps the push
            // animation smooth, and reusing the document means flipping the
            // layout does not re-read the file.
            .task(id: url) {
                document = await Task.detached(priority: .userInitiated) {
                    LoadedDocument(document: PDFDocument(url: url))
                }.value.document
            }
            .onChange(of: visiblePages) { _, pages in
                guard let selectedRegion, !pages.contains(selectedRegion.pdfPage) else { return }
                self.selectedRegion = nil
                proxy.clearRegionSelection()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerContainerWillResize)) { _ in
                guard !reduceMotion else { return }
                proxy.prepareForAnimatedResize(duration: 0.45)
            }
            .onChange(of: askingBookAI) {
                guard horizontalSizeClass != .compact, !reduceMotion else { return }
                proxy.prepareForAnimatedResize(duration: 0.48)
            }
    }

    /// On iPad the panel and reader share one animatable layout. A native
    /// inspector changes its presenting column outside SwiftUI's transaction,
    /// which made the PDF and its bottom controls jump directly to their final
    /// positions even while the panel itself was moving. Compact devices keep
    /// the familiar sheet and therefore do not resize the book at all.
    @ViewBuilder private var adaptiveReader: some View {
        if horizontalSizeClass == .compact {
            reader
                .sheet(isPresented: assistantPresentation) {
                    bookAIPanel
                        .presentationDetents([.medium, .large], selection: $bookAIDetent)
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Color.black)
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
        } else {
            GeometryReader { geometry in
                let panelWidth = min(max(geometry.size.width * 0.32, 320), 480)
                HStack(spacing: 0) {
                    reader
                        .frame(
                            width: max(
                                geometry.size.width - (askingBookAI ? panelWidth : 0),
                                0
                            )
                        )

                    if askingBookAI {
                        bookAIPanel
                            .frame(width: panelWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .clipped()
                .animation(assistantAnimation, value: askingBookAI)
            }
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
                    selectedRegion: $selectedRegion
                )
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
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if selectedRegion != nil {
                selectedRegionBanner
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(assistantAnimation, value: selectingRegion)
        .animation(assistantAnimation, value: selectedRegion != nil)
        .safeAreaInset(edge: .bottom, spacing: 0) { controlBar }
    }

    // MARK: - Seite fragen

    private var bookAIPanel: some View {
        BookAIPanel(
            bookID: book.id,
            numbering: numbering,
            visiblePages: visiblePages,
            region: selectedRegion,
            store: bookAI,
            detent: $bookAIDetent,
            goToPage: { page in
                proxy.go(toPage: page)
            },
            requestRegion: beginRegionSelection
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

    private var selectedRegionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
            VStack(alignment: .leading, spacing: 1) {
                Text("Bereich ausgewählt")
                    .font(.subheadline.weight(.medium))
                Text("Ziehen oder an den Eckpunkten anpassen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Aufheben", systemImage: "xmark", action: clearRegionSelection)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Verwendet wieder die ganze Seite")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 48)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func beginRegionSelection() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            selectingRegion = true
            selectedRegion = nil
        }
        proxy.clearRegionSelection()
        // The chat remains visible while its reader enters selection mode. As
        // the reader no longer changes width here, the overlay starts against
        // stable bounds and there is no panel-close/reopen animation to fight.
        DispatchQueue.main.async {
            proxy.beginRegionSelection { region in
                bookAIDetent = .medium
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                    selectedRegion = region
                    selectingRegion = false
                }
            }
        }
    }

    private func clearRegionSelection() {
        selectedRegion = nil
        selectingRegion = false
        proxy.cancelRegionSelection()
        proxy.clearRegionSelection()
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

    /// Page layout and navigation remain in the bottom bar; Book AI now lives
    /// exclusively in the upper-left toolbar.
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
        .background(Color.black.ignoresSafeArea())
    }

    /// Previous/next buttons around the current page. Editing happens directly
    /// in this stable control row so the first tap can focus the field and show
    /// the number pad without presenting an unfocused intermediate popover.
    private var pageControls: some View {
        HStack(spacing: 12) {
            Button {
                proxy.step(-1)
            } label: {
                Image(systemName: "arrow.left")
            }
            .disabled(currentPage <= 1)
            .accessibilityLabel("Vorherige Seite")

            if askingForPage {
                pageJump
            } else {
                pageIndicator
            }

            Button {
                if askingForPage {
                    confirmPageJump()
                } else {
                    proxy.step(1)
                }
            } label: {
                Image(systemName: askingForPage ? "checkmark" : "arrow.right")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(
                askingForPage
                    ? numbering.pdfPage(forPrinted: Int(typedPage) ?? 0) == nil
                    : pageCount > 0 && currentPage >= pageCount
            )
            .accessibilityLabel(askingForPage ? "Seite öffnen" : "Nächste Seite")
        }
        .buttonStyle(.glass)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: askingForPage)
    }

    /// The current page, and the way to jump to another one.
    private var pageIndicator: some View {
        Button {
            typedPage = printedLabel(currentPage)
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
    }

    /// The current value is selected when the field becomes first responder,
    /// so typing replaces it immediately. The keyboard's Done button and the
    /// row's checkmark share the same direct navigation path.
    private var pageJump: some View {
        HStack(spacing: 8) {
            AutoFocusPageNumberField(text: $typedPage, onCommit: confirmPageJump)
                .frame(width: 48, height: 32)
                .accessibilityLabel("Seitennummer")

            Text("/ \(printedLast)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .onChange(of: typedPage) { _, text in
            let digits = String(text.filter(\.isNumber).prefix(5))
            if digits != text { typedPage = digits }
        }
    }

    private func confirmPageJump() {
        guard let requested = Int(typedPage), printedLast > 0 else { return }
        let first = numbering.printedNumber(1) ?? 1
        let constrained = min(max(requested, first), printedLast)
        guard let pdfPage = numbering.pdfPage(forPrinted: constrained) else { return }
        typedPage = String(constrained)
        proxy.go(toPage: pdfPage)
        askingForPage = false
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

            if model.settings.showPageNumberEditor {
                Divider()

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
            }
        } label: {
            Image(systemName: twoUp ? "rectangle.portrait.on.rectangle.portrait" : "rectangle.portrait")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Seitendarstellung")
        .popover(isPresented: $adjustingNumbering) { numberingEditor }
    }
}

/// A number-pad field that becomes first responder as soon as SwiftUI inserts
/// it into the existing control bar. Unlike a newly presented popover, it has a
/// window immediately, so one tap on the page indicator reliably shows the
/// keypad. Selecting the existing value makes the next digit replace it.
private struct AutoFocusPageNumberField: UIViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = FirstResponderNumberField()
        field.keyboardType = .numberPad
        field.textAlignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        field.textColor = .label
        field.tintColor = .systemBlue
        field.backgroundColor = .clear
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.accessibilityLabel = "Seitennummer"

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(
                title: "Fertig",
                style: .done,
                target: context.coordinator,
                action: #selector(Coordinator.commit)
            ),
        ]
        field.inputAccessoryView = toolbar
        context.coordinator.field = field
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AutoFocusPageNumberField
        weak var field: UITextField?

        init(parent: AutoFocusPageNumberField) {
            self.parent = parent
        }

        @objc func changed(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        @objc func commit() {
            parent.onCommit()
            field?.resignFirstResponder()
        }
    }

    private final class FirstResponderNumberField: UITextField {
        private var focusedOnce = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !focusedOnce else { return }
            focusedOnce = true
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil else { return }
                becomeFirstResponder()
                selectAll(nil)
            }
        }
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
private final class BookPageRenderCache {
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

        var pageSize = page.getBoxRect(.cropBox).standardized.size
        let rotation = abs(page.rotationAngle) % 180
        if rotation == 90 { pageSize = CGSize(width: pageSize.height, height: pageSize.width) }
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }

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
        context.concatenate(
            page.getDrawingTransform(
                .cropBox,
                rect: target,
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        context.drawPDFPage(page)
        guard let rendered = context.makeImage() else { return nil }
        return UIImage(cgImage: rendered)
    }
}

/// A swipe that remembers where the finger landed. UISwipeGestureRecognizer
/// only reports where the flick ended, which is no use for telling a page turn
/// apart from a back swipe that started at the screen edge.
private final class PageSwipeGestureRecognizer: UISwipeGestureRecognizer {
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
private final class BookPDFView: PDFView {
    /// Breathing room left around the page at its smallest, in points.
    private let margin: CGFloat = 14
    /// The scale the page rests at: its natural size on this screen, and the
    /// point below which zooming out stops.
    private(set) var restingScale: CGFloat = 0
    private var selectionOverlay: BookRegionSelectionOverlay?
    private var adjustmentOverlay: BookRegionAdjustmentOverlay?
    private var displayedRegion: BackendAPI.BookPageRegion?
    private var resizeSnapshot: UIView?
    private var resizeCompletion: DispatchWorkItem?
    private var hiddenDuringResize: [UIView] = []
    private var holdsPDFLayout = false
    private var resizeSnapshotBaseBounds = CGRect.zero
    private var resizeSnapshotContentFrame = CGRect.zero
    private var resizeSnapshotFollowsFit = false
    private var pageRenderCache: BookPageRenderCache?
    private var finalQualityOverlay: UIView?
    private var layoutTransitionOverlay: UIView?
    private var navigationGeneration = 0
    private var layoutGeneration = 0
    private weak var observedScrollView: UIScrollView?
    private var scrollObservations: [NSKeyValueObservation] = []
    private lazy var deselectionTap = UITapGestureRecognizer(
        target: self,
        action: #selector(tappedOutsideSelection)
    )
    var onRegionChanged: ((BackendAPI.BookPageRegion?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureRegionInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRegionInteraction()
    }

    private func configureRegionInteraction() {
        deselectionTap.cancelsTouchesInView = false
        deselectionTap.delegate = self
        addGestureRecognizer(deselectionTap)
    }

    override func layoutSubviews() {
        // PDFKit rebuilds page tiles synchronously for every intermediate width
        // of a split-view animation. Keep its hierarchy at the last stable
        // layout while a lightweight snapshot follows the system animation.
        if holdsPDFLayout {
            updateResizeSnapshotLayout()
            if let resizeSnapshot { bringSubviewToFront(resizeSnapshot) }
            return
        }
        super.layoutSubviews()
        applyScaleLimits()
        prepareVisibleAndNeighboringPages()
        selectionOverlay?.frame = bounds
        observeScrollingIfNeeded()
        updateDisplayedRegion()
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    func beginRegionSelection(onSelected: @escaping (BackendAPI.BookPageRegion) -> Void) {
        cancelRegionSelection()
        let overlay = BookRegionSelectionOverlay(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onFinished = { [weak self, weak overlay] rect in
            guard let self else { return }
            let converted = overlay?.convert(rect, to: self) ?? rect
            if let region = normalizedRegion(from: converted) {
                display(region: region)
                onSelected(region)
                cancelRegionSelection()
            }
        }
        addSubview(overlay)
        selectionOverlay = overlay
        prioritizeRegionGestures(overlay.gestureRecognizers ?? [])
    }

    func cancelRegionSelection() {
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
    }

    func display(region: BackendAPI.BookPageRegion?) {
        displayedRegion = region
        if region == nil {
            adjustmentOverlay?.removeFromSuperview()
            adjustmentOverlay = nil
        } else {
            installAdjustmentOverlayIfNeeded()
        }
        updateDisplayedRegion()
    }

    private func normalizedRegion(
        from selection: CGRect,
        on preferredPage: PDFPage? = nil
    ) -> BackendAPI.BookPageRegion? {
        guard selection.width >= 18, selection.height >= 18,
              let document,
              let page = preferredPage ?? page(for: CGPoint(x: selection.midX, y: selection.midY), nearest: true)
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
        guard let region = displayedRegion,
              let document,
              let page = document.page(at: region.pdfPage - 1)
        else {
            adjustmentOverlay?.isHidden = true
            return
        }
        installAdjustmentOverlayIfNeeded()
        let pageBounds = page.bounds(for: .cropBox)
        let pdfRect = CGRect(
            x: pageBounds.minX + pageBounds.width * CGFloat(region.x),
            y: pageBounds.minY + pageBounds.height * CGFloat(region.y),
            width: pageBounds.width * CGFloat(region.width),
            height: pageBounds.height * CGFloat(region.height)
        )
        let pageFrame = convert(pageBounds, from: page)
        let selectionFrame = convert(pdfRect, from: page).standardized.intersection(pageFrame)
        guard !selectionFrame.isNull, selectionFrame.width > 0, selectionFrame.height > 0 else {
            adjustmentOverlay?.isHidden = true
            return
        }
        adjustmentOverlay?.isHidden = false
        adjustmentOverlay?.allowedFrame = pageFrame
        adjustmentOverlay?.setSelectionFrame(selectionFrame)
        if let adjustmentOverlay { bringSubviewToFront(adjustmentOverlay) }
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    private func installAdjustmentOverlayIfNeeded() {
        guard adjustmentOverlay == nil else { return }
        let overlay = BookRegionAdjustmentOverlay(frame: .zero)
        overlay.onFrameChanged = { [weak self] frame in
            guard let self,
                  let current = displayedRegion,
                  let page = document?.page(at: current.pdfPage - 1),
                  let updated = normalizedRegion(from: frame, on: page)
            else { return }
            displayedRegion = updated
        }
        overlay.onFrameCommitted = { [weak self] frame in
            guard let self,
                  let current = displayedRegion,
                  let page = document?.page(at: current.pdfPage - 1),
                  let updated = normalizedRegion(from: frame, on: page)
            else { return }
            displayedRegion = updated
            onRegionChanged?(updated)
        }
        overlay.onClear = { [weak self] in
            guard let self else { return }
            display(region: nil)
            onRegionChanged?(nil)
        }
        addSubview(overlay)
        adjustmentOverlay = overlay
        prioritizeRegionGestures(overlay.interactionRecognizers)
    }

    /// PDFKit scrolls and zooms an internal scroll view, so PDFView itself does
    /// not reliably receive a layout pass while the page moves. Tracking those
    /// values keeps the editable rectangle attached to the exact PDF
    /// coordinates through zooming, panning and orientation changes.
    private func observeScrollingIfNeeded() {
        guard observedScrollView == nil,
              let scrollView = descendantScrollView(in: self)
        else { return }
        observedScrollView = scrollView
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(readerInteractionBegan(_:)))
        scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(readerInteractionBegan(_:)))
        if let adjustmentOverlay {
            prioritizeRegionGestures(adjustmentOverlay.interactionRecognizers)
        }
        scrollObservations = [
            scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.updateDisplayedRegion()
            },
            scrollView.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
                self?.updateDisplayedRegion()
            },
            scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.updateDisplayedRegion()
            },
        ]
    }

    @objc private func readerInteractionBegan(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began else { return }
        discardFinalQualityOverlay()
    }

    private func descendantScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = descendantScrollView(in: subview) { return nested }
        }
        return nil
    }

    @objc private func tappedOutsideSelection(_ recognizer: UITapGestureRecognizer) {
        guard let overlay = adjustmentOverlay, !overlay.isHidden, !overlay.isInteracting else { return }
        let point = recognizer.location(in: self)
        guard !regionControlsContain(point) else { return }
        display(region: nil)
        onRegionChanged?(nil)
    }

    func regionControlsContain(_ point: CGPoint) -> Bool {
        guard let overlay = adjustmentOverlay, !overlay.isHidden else { return false }
        return overlay.frame.insetBy(dx: -24, dy: -24).contains(point)
    }

    private func prioritizeRegionGestures(_ recognizers: [UIGestureRecognizer]) {
        guard !recognizers.isEmpty else { return }
        let pageSwipes = gestureRecognizers?.compactMap { $0 as? PageSwipeGestureRecognizer } ?? []
        let scrollPan = descendantScrollView(in: self)?.panGestureRecognizer

        for recognizer in recognizers {
            deselectionTap.require(toFail: recognizer)
            scrollPan?.require(toFail: recognizer)
            for swipe in pageSwipes {
                swipe.require(toFail: recognizer)
            }
        }
    }

    override func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === deselectionTap || otherGestureRecognizer === deselectionTap {
            return true
        }
        return super.gestureRecognizer(
            gestureRecognizer,
            shouldRecognizeSimultaneouslyWith: otherGestureRecognizer
        )
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
        if abs(minScaleFactor - fit) > 0.0005 {
            minScaleFactor = fit
        }
        if abs(maxScaleFactor - fit * 6) > 0.0005 {
            maxScaleFactor = fit * 6
        }
        if restingAtFit || scaleFactor < fit, abs(scaleFactor - fit) > 0.001 {
            scaleFactor = fit
        }
        restingScale = fit
    }

    /// Page turns never expose PDFKit's provisional tiled render. Neighboring
    /// pages should already be in the device-resolution cache; if a distant
    /// jump misses, the old page remains visible until that same final-quality
    /// render is ready, then the navigation and overlay install happen in one
    /// main-thread turn before the next frame is displayed.
    func goToPageAtFinalQuality(_ pageIndex: Int) {
        guard let document, document.pageCount > 0 else { return }
        let clamped = min(max(pageIndex, 0), document.pageCount - 1)
        let targets = expectedPageIndices(containing: clamped, twoUp: displaysAsBook)
        let dimension = renderPixelDimension
        guard let cache = pageCache else {
            if let page = document.page(at: clamped) { go(to: page) }
            return
        }

        navigationGeneration += 1
        let generation = navigationGeneration
        cache.prepare(pageIndices: targets, maxPixelDimension: dimension) { [weak self] in
            guard let self, generation == navigationGeneration,
                  let page = self.document?.page(at: clamped)
            else { return }
            discardFinalQualityOverlay()
            go(to: page)
            layoutDocumentView()
            layoutIfNeeded()
            applyScaleLimits()
            installFinalQualityOverlay()
            prepareVisibleAndNeighboringPages()
        }
    }

    /// Change PDFKit's layout in place. Device-resolution page planes cover the
    /// live tiles and move between their old and new frames; newly added pages
    /// enter from the side and removed pages leave spatially, with no opacity
    /// animation or replacement of the representable.
    func setPageLayout(twoUp: Bool, anchorPage: Int, animated: Bool) {
        let targetMode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        guard displayMode != targetMode || displaysAsBook != twoUp else {
            // Invalidates an asynchronous render requested for a mode the user
            // has already toggled away from.
            layoutGeneration += 1
            return
        }

        guard let document, document.pageCount > 0 else { return }
        let anchorIndex = min(max(anchorPage - 1, 0), document.pageCount - 1)
        let current = Set(visiblePages.map { document.index(for: $0) })
        let target = expectedPageIndices(containing: anchorIndex, twoUp: twoUp)
        let required = current.union(target)
        let dimension = renderPixelDimension

        layoutGeneration += 1
        let generation = layoutGeneration
        guard let cache = pageCache else {
            performPageLayout(twoUp: twoUp, anchorIndex: anchorIndex, animated: animated)
            return
        }
        cache.prepare(pageIndices: required, maxPixelDimension: dimension) { [weak self] in
            guard let self, generation == layoutGeneration else { return }
            performPageLayout(twoUp: twoUp, anchorIndex: anchorIndex, animated: animated)
        }
    }

    private func performPageLayout(twoUp: Bool, anchorIndex: Int, animated: Bool) {
        guard let document, let anchor = document.page(at: anchorIndex) else { return }
        completePendingResize()
        layoutTransitionOverlay?.removeFromSuperview()
        layoutTransitionOverlay = nil

        let dimension = renderPixelDimension
        let oldPages = Dictionary(uniqueKeysWithValues: visiblePages.map {
            (document.index(for: $0), convert($0.bounds(for: .cropBox), from: $0).standardized)
        })
        let zoomRatio = restingScale > 0 ? max(scaleFactor / restingScale, 1) : 1
        discardFinalQualityOverlay()

        displayMode = twoUp ? .twoUp : .singlePage
        displaysAsBook = twoUp
        go(to: anchor)
        restingScale = 0
        layoutDocumentView()
        setNeedsLayout()
        layoutIfNeeded()
        applyScaleLimits()
        if zoomRatio > 1.001, restingScale > 0 {
            scaleFactor = min(restingScale * zoomRatio, maxScaleFactor)
        }

        let newPages = Dictionary(uniqueKeysWithValues: visiblePages.map {
            (document.index(for: $0), convert($0.bounds(for: .cropBox), from: $0).standardized)
        })
        guard animated, !oldPages.isEmpty, !newPages.isEmpty else {
            installFinalQualityOverlay()
            prepareVisibleAndNeighboringPages()
            return
        }

        installSpatialLayoutTransition(oldPages: oldPages, newPages: newPages, dimension: dimension)
    }

    private func installSpatialLayoutTransition(
        oldPages: [Int: CGRect],
        newPages: [Int: CGRect],
        dimension: Int
    ) {
        let canvas = UIView(frame: bounds)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.isUserInteractionEnabled = false
        canvas.accessibilityElementsHidden = true
        for frame in newPages.values {
            let cover = UIView(frame: frame)
            cover.backgroundColor = .systemGroupedBackground
            canvas.addSubview(cover)
        }

        struct MovingPage {
            let view: UIImageView
            let destination: CGRect
        }
        var moving: [MovingPage] = []
        let retained = Set(oldPages.keys).intersection(newPages.keys)
        let retainedCenter = retained.first.flatMap { newPages[$0]?.midX } ?? bounds.midX
        for pageIndex in Set(oldPages.keys).union(newPages.keys).sorted() {
            guard let image = pageCache?.image(pageIndex: pageIndex, maxPixelDimension: dimension) else {
                continue
            }
            guard let frames = transitionFrames(
                pageIndex: pageIndex,
                oldPages: oldPages,
                newPages: newPages,
                retainedCenter: retainedCenter
            ) else { continue }
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            imageView.clipsToBounds = true
            imageView.frame = frames.start
            canvas.addSubview(imageView)
            moving.append(MovingPage(view: imageView, destination: frames.destination))
        }

        addSubview(canvas)
        layoutTransitionOverlay = canvas
        if let adjustmentOverlay { bringSubviewToFront(adjustmentOverlay) }
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }

        UIView.animate(
            withDuration: 0.36,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
        ) {
            moving.forEach { $0.view.frame = $0.destination }
        } completion: { [weak self, weak canvas] _ in
            guard let self else { return }
            installFinalQualityOverlay()
            canvas?.removeFromSuperview()
            if layoutTransitionOverlay === canvas { layoutTransitionOverlay = nil }
            prepareVisibleAndNeighboringPages()
        }
    }

    private func transitionFrames(
        pageIndex: Int,
        oldPages: [Int: CGRect],
        newPages: [Int: CGRect],
        retainedCenter: CGFloat
    ) -> (start: CGRect, destination: CGRect)? {
        switch (oldPages[pageIndex], newPages[pageIndex]) {
        case let (oldFrame?, newFrame?):
            (oldFrame, newFrame)
        case let (nil, newFrame?):
            (
                offscreenFrame(newFrame, movesRight: newFrame.midX >= retainedCenter),
                newFrame
            )
        case let (oldFrame?, nil):
            (
                oldFrame,
                offscreenFrame(oldFrame, movesRight: oldFrame.midX >= retainedCenter)
            )
        case (nil, nil):
            nil
        }
    }

    private func offscreenFrame(_ frame: CGRect, movesRight: Bool) -> CGRect {
        frame.offsetBy(dx: movesRight ? bounds.width + margin : -(bounds.width + margin), dy: 0)
    }

    private var pageCache: BookPageRenderCache? {
        if pageRenderCache == nil, let document {
            pageRenderCache = BookPageRenderCache(document: document)
        }
        return pageRenderCache
    }

    private var renderPixelDimension: Int {
        let displayScale = window?.screen.scale ?? traitCollection.displayScale
        let zoomRatio = restingScale > 0 ? max(scaleFactor / restingScale, 1) : 1
        return max(256, Int(ceil(max(bounds.width, bounds.height) * displayScale * zoomRatio)))
    }

    private func expectedPageIndices(containing pageIndex: Int, twoUp: Bool) -> Set<Int> {
        guard let document, document.pageCount > 0 else { return [] }
        let clamped = min(max(pageIndex, 0), document.pageCount - 1)
        guard twoUp, clamped > 0 else { return [clamped] }
        let first = clamped.isMultiple(of: 2) ? clamped - 1 : clamped
        return Set([first, first + 1].filter { $0 < document.pageCount })
    }

    private func prepareVisibleAndNeighboringPages() {
        guard let document, bounds.width > 40, bounds.height > 40 else { return }
        let visible = visiblePages.map { document.index(for: $0) }
        guard let first = visible.min(), let last = visible.max() else { return }
        let nearby = Set(max(0, first - 2) ... min(document.pageCount - 1, last + 2))
        pageCache?.prepare(pageIndices: nearby, maxPixelDimension: renderPixelDimension)
    }

    private func installFinalQualityOverlay() {
        guard let document, let cache = pageCache else { return }
        let dimension = renderPixelDimension
        let pageFrames = visiblePages.compactMap { page -> (Int, CGRect)? in
            let index = document.index(for: page)
            let frame = convert(page.bounds(for: .cropBox), from: page).standardized
            return frame.isEmpty ? nil : (index, frame)
        }
        guard !pageFrames.isEmpty,
              pageFrames.allSatisfy({ cache.image(pageIndex: $0.0, maxPixelDimension: dimension) != nil })
        else { return }

        discardFinalQualityOverlay()
        let overlay = UIView(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        for (pageIndex, frame) in pageFrames {
            guard let image = cache.image(pageIndex: pageIndex, maxPixelDimension: dimension) else { continue }
            let imageView = UIImageView(image: image)
            imageView.frame = frame
            imageView.contentMode = .scaleToFill
            imageView.clipsToBounds = true
            overlay.addSubview(imageView)
        }
        addSubview(overlay)
        finalQualityOverlay = overlay
        if let adjustmentOverlay { bringSubviewToFront(adjustmentOverlay) }
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    private func discardFinalQualityOverlay() {
        finalQualityOverlay?.removeFromSuperview()
        finalQualityOverlay = nil
    }

    private func completePendingResize() {
        resizeCompletion?.cancel()
        resizeCompletion = nil
        guard holdsPDFLayout || resizeSnapshot != nil else { return }
        holdsPDFLayout = false
        hiddenDuringResize.forEach { $0.isHidden = false }
        hiddenDuringResize.removeAll(keepingCapacity: true)
        discardResizeSnapshot()
        super.layoutSubviews()
    }

    /// Freeze only PDFKit's expensive internal layout during a known animated
    /// container resize. The page snapshot scales uniformly to the new fit;
    /// assigning it the changing bounds directly would squeeze the spread only
    /// horizontally. The live PDF is laid out once at the final size and then
    /// cross-faded back in.
    func prepareForAnimatedResize(duration: TimeInterval) {
        discardFinalQualityOverlay()
        resizeCompletion?.cancel()
        if !holdsPDFLayout {
            // A second toggle can arrive during the one-run-loop hand-off to
            // live PDFKit. Complete that hand-off before capturing the next
            // snapshot so no hidden selection overlay is inherited.
            if resizeSnapshot != nil { finishResizeHandoff() }
            discardResizeSnapshot()
        }
        if !holdsPDFLayout,
           bounds.width > 0,
           bounds.height > 0,
           let snapshot = snapshotView(afterScreenUpdates: false) {
            resizeSnapshotBaseBounds = bounds
            resizeSnapshotContentFrame = visiblePageFrame ?? bounds
            resizeSnapshotFollowsFit = restingScale == 0 || abs(scaleFactor - restingScale) < 0.001
            hiddenDuringResize = subviews.filter { !$0.isHidden }
            hiddenDuringResize.forEach { $0.isHidden = true }
            snapshot.bounds = CGRect(origin: .zero, size: bounds.size)
            snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
            snapshot.autoresizingMask = []
            snapshot.isUserInteractionEnabled = false
            snapshot.layer.minificationFilter = .trilinear
            snapshot.layer.magnificationFilter = .linear
            addSubview(snapshot)
            resizeSnapshot = snapshot
            holdsPDFLayout = true
        }
        guard holdsPDFLayout else { return }

        let completion = DispatchWorkItem { [weak self] in
            self?.finishAnimatedResize()
        }
        resizeCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: completion)
    }

    private var visiblePageFrame: CGRect? {
        let frames = visiblePages.map { page in
            convert(page.bounds(for: .cropBox), from: page).standardized
        }.filter { !$0.isNull && !$0.isEmpty }
        guard var frame = frames.first else { return nil }
        for next in frames.dropFirst() {
            frame = frame.union(next)
        }
        return frame
    }

    /// Keeps both axes at one scale throughout the resize. The scale is based
    /// on the visible page rectangle rather than the whole PDFView, whose large
    /// black margins would incorrectly prevent a narrow spread from growing
    /// again when the assistant closes.
    private func updateResizeSnapshotLayout() {
        guard let snapshot = resizeSnapshot,
              resizeSnapshotBaseBounds.width > 0,
              resizeSnapshotBaseBounds.height > 0
        else { return }

        let scale: CGFloat
        if resizeSnapshotFollowsFit {
            let originalFit = snapshotFit(in: resizeSnapshotBaseBounds.size)
            let currentFit = snapshotFit(in: bounds.size)
            scale = originalFit > 0 ? currentFit / originalFit : 1
        } else {
            // Preserve a deliberately zoomed page instead of snapping it back
            // to the minimum fit merely because a panel was opened.
            scale = 1
        }

        let baseCenter = CGPoint(
            x: resizeSnapshotBaseBounds.midX,
            y: resizeSnapshotBaseBounds.midY
        )
        let contentOffset = CGPoint(
            x: resizeSnapshotContentFrame.midX - baseCenter.x,
            y: resizeSnapshotContentFrame.midY - baseCenter.y
        )
        snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
        if resizeSnapshotFollowsFit {
            snapshot.center = CGPoint(
                x: bounds.midX - scale * contentOffset.x,
                y: bounds.midY - scale * contentOffset.y
            )
        } else {
            snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private func snapshotFit(in size: CGSize) -> CGFloat {
        guard resizeSnapshotContentFrame.width > 0,
              resizeSnapshotContentFrame.height > 0,
              size.width > 2 * margin,
              size.height > 2 * margin
        else { return 1 }
        return min(
            (size.width - 2 * margin) / resizeSnapshotContentFrame.width,
            (size.height - 2 * margin) / resizeSnapshotContentFrame.height
        )
    }

    private func finishAnimatedResize() {
        guard holdsPDFLayout else { return }
        resizeCompletion = nil
        holdsPDFLayout = false

        // Restore PDFKit's tiles for the final layout, but keep live selection
        // controls hidden while the snapshot still contains their old copy.
        // Showing both copies during the hand-off produced the doubled blue
        // rectangle visible in the recording.
        let regionViews: [UIView] = [
            selectionOverlay as UIView?,
            adjustmentOverlay as UIView?,
        ].compactMap { $0 }
        hiddenDuringResize
            .filter { hidden in !regionViews.contains(where: { $0 === hidden }) }
            .forEach { $0.isHidden = false }
        setNeedsLayout()
        layoutIfNeeded()
        regionViews.forEach { $0.isHidden = true }

        guard let snapshot = resizeSnapshot else {
            finishResizeHandoff()
            return
        }
        alignResizeSnapshot(to: visiblePageFrame)
        bringSubviewToFront(snapshot)

        // Give PDFKit one display pass to populate its final tiles. The old
        // cross-fade exposed tiny fit differences as a last-frame zoom; after
        // aligning both page rectangles, a direct hand-off is seamless.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if resizeSnapshot === snapshot, !holdsPDFLayout {
                layoutIfNeeded()
                alignResizeSnapshot(to: visiblePageFrame)
                discardResizeSnapshot()
                finishResizeHandoff()
            } else {
                snapshot.removeFromSuperview()
            }
        }
    }

    /// Match the snapshot's captured page rectangle to PDFKit's exact final
    /// page rectangle. This removes the tiny correction zoom at the end of an
    /// otherwise smooth assistant/sidebar animation.
    private func alignResizeSnapshot(to finalContentFrame: CGRect?) {
        guard let snapshot = resizeSnapshot,
              let finalContentFrame,
              resizeSnapshotContentFrame.width > 0,
              resizeSnapshotContentFrame.height > 0
        else { return }

        let scale = min(
            finalContentFrame.width / resizeSnapshotContentFrame.width,
            finalContentFrame.height / resizeSnapshotContentFrame.height
        )
        guard scale > 0, scale.isFinite else { return }

        let snapshotCenter = CGPoint(
            x: resizeSnapshotBaseBounds.midX,
            y: resizeSnapshotBaseBounds.midY
        )
        let contentOffset = CGPoint(
            x: resizeSnapshotContentFrame.midX - snapshotCenter.x,
            y: resizeSnapshotContentFrame.midY - snapshotCenter.y
        )
        snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
        snapshot.center = CGPoint(
            x: finalContentFrame.midX - scale * contentOffset.x,
            y: finalContentFrame.midY - scale * contentOffset.y
        )
    }

    private func finishResizeHandoff() {
        hiddenDuringResize.forEach { $0.isHidden = false }
        hiddenDuringResize.removeAll(keepingCapacity: true)
        updateDisplayedRegion()
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    private func discardResizeSnapshot() {
        resizeSnapshot?.layer.removeAllAnimations()
        resizeSnapshot?.removeFromSuperview()
        resizeSnapshot = nil
        resizeSnapshotBaseBounds = .zero
        resizeSnapshotContentFrame = .zero
        resizeSnapshotFollowsFit = false
    }

    deinit {
        resizeCompletion?.cancel()
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
private final class BookRegionSelectionOverlay: UIView {
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
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
    }

    @available(*, unavailable)
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
