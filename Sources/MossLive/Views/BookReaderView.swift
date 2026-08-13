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
        if let page = document.page(at: clamped) { pdfView.go(to: page) }
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

    /// Change PDFKit's layout in place. Replacing the representable destroys
    /// the live page hierarchy and is what exposed the white intermediate
    /// frames in the recording. A snapshot of the already rendered pages stays
    /// above PDFKit while it lays out the new mode, then moves/scales to the new
    /// page frame and hands off to the live tiles underneath.
    func setPageLayout(twoUp: Bool, anchorPage: Int, animated: Bool) {
        let targetMode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        guard displayMode != targetMode || displaysAsBook != twoUp else { return }

        completePendingResize()
        let oldContentFrame = visiblePageFrame ?? bounds
        // Reduced Motion still keeps a snapshot until PDFKit's final tiles are
        // ready; it simply performs a direct hand-off instead of animating it.
        let snapshot = snapshotView(afterScreenUpdates: false)
        let zoomRatio = restingScale > 0 ? max(scaleFactor / restingScale, 1) : 1

        displayMode = targetMode
        displaysAsBook = twoUp
        if let document,
           let page = document.page(at: min(max(anchorPage - 1, 0), max(document.pageCount - 1, 0))) {
            go(to: page)
        }
        restingScale = 0
        layoutDocumentView()
        setNeedsLayout()
        layoutIfNeeded()
        applyScaleLimits()
        if zoomRatio > 1.001, restingScale > 0 {
            scaleFactor = min(restingScale * zoomRatio, maxScaleFactor)
        }

        guard let snapshot, bounds.width > 0, bounds.height > 0 else { return }
        snapshot.frame = bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        snapshot.layer.minificationFilter = .trilinear
        snapshot.layer.magnificationFilter = .linear
        addSubview(snapshot)

        // PDFKit posts its visible-page update on the next run loop. Keep the
        // old rendered pages fully opaque until that final page frame exists.
        DispatchQueue.main.async { [weak self, weak snapshot] in
            guard let self, let snapshot, snapshot.superview === self else { return }
            layoutDocumentView()
            layoutIfNeeded()
            applyScaleLimits()
            let finalContentFrame = visiblePageFrame ?? bounds
            let scale = min(
                finalContentFrame.width / max(oldContentFrame.width, 1),
                finalContentFrame.height / max(oldContentFrame.height, 1)
            )
            let baseCenter = CGPoint(x: bounds.midX, y: bounds.midY)
            let oldOffset = CGPoint(
                x: oldContentFrame.midX - baseCenter.x,
                y: oldContentFrame.midY - baseCenter.y
            )

            guard animated else {
                snapshot.removeFromSuperview()
                return
            }

            UIView.animate(
                withDuration: 0.34,
                delay: 0.06,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
            ) {
                snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
                snapshot.center = CGPoint(
                    x: finalContentFrame.midX - scale * oldOffset.x,
                    y: finalContentFrame.midY - scale * oldOffset.y
                )
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }
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
        let targetMode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        if bookView.displayMode != targetMode || bookView.displaysAsBook != twoUp {
            bookView.setPageLayout(
                twoUp: twoUp,
                anchorPage: currentPage,
                animated: !UIAccessibility.isReduceMotionEnabled
            )
        }
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

/// An editable, page-anchored selection. The entire rectangle is draggable and
/// each corner has a generous touch target with a small visible handle, which
/// mirrors the way system crop and text-selection controls separate visual
/// weight from hit-target size.
private final class BookRegionAdjustmentOverlay: UIView, UIGestureRecognizerDelegate {
    var onFrameChanged: ((CGRect) -> Void)?
    var onFrameCommitted: ((CGRect) -> Void)?
    var onClear: (() -> Void)?
    var allowedFrame = CGRect.zero

    private enum Corner: CaseIterable, Hashable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    private let border = CAShapeLayer()
    private var handles: [Corner: BookRegionHandleView] = [:]
    private var startingFrame = CGRect.zero
    private(set) var isInteracting = false
    private let minimumSide: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        backgroundColor = .clear

        border.fillColor = UIColor.systemBlue.withAlphaComponent(0.11).cgColor
        border.strokeColor = UIColor.systemBlue.cgColor
        border.lineWidth = 2
        border.lineJoin = .round
        layer.addSublayer(border)

        let move = UIPanGestureRecognizer(target: self, action: #selector(moved))
        move.delegate = self
        addGestureRecognizer(move)

        for corner in Corner.allCases {
            let handle = BookRegionHandleView(frame: .zero)
            handle.accessibilityLabel = accessibilityLabel(for: corner)
            let resize = UIPanGestureRecognizer(target: self, action: #selector(resized(_:)))
            resize.name = gestureName(for: corner)
            handle.addGestureRecognizer(resize)
            addSubview(handle)
            handles[corner] = handle
        }

        isAccessibilityElement = true
        accessibilityLabel = "Ausgewählter Buchbereich"
        accessibilityHint = "Zum Verschieben ziehen oder die Eckpunkte zum Ändern der Größe verwenden."
        accessibilityTraits = [.adjustable]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: "Auswahl aufheben",
                target: self,
                selector: #selector(clearSelection)
            ),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        border.frame = bounds
        border.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerRadius: 7
        ).cgPath

        let target: CGFloat = 44
        for (corner, handle) in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: target, height: target)
            handle.center = CGPoint(
                x: corner.isLeft ? 0 : bounds.width,
                y: corner.isTop ? 0 : bounds.height
            )
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return handles.values.contains { handle in
            handle.point(inside: convert(point, to: handle), with: event)
        }
    }

    func setSelectionFrame(_ newFrame: CGRect) {
        guard !isInteracting else { return }
        frame = newFrame.standardized
    }

    var interactionRecognizers: [UIGestureRecognizer] {
        let move = gestureRecognizers ?? []
        let resize = handles.values.flatMap { $0.gestureRecognizers ?? [] }
        return move + resize
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        !handles.values.contains { handle in
            guard let touchedView = touch.view else { return false }
            return touchedView === handle || touchedView.isDescendant(of: handle)
        }
    }

    @objc private func moved(_ recognizer: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        switch recognizer.state {
        case .began:
            isInteracting = true
            startingFrame = frame
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            let translation = recognizer.translation(in: container)
            frame = clampedMovedFrame(
                startingFrame.offsetBy(dx: translation.x, dy: translation.y)
            )
            onFrameChanged?(frame)
        case .ended:
            isInteracting = false
            onFrameCommitted?(frame)
        case .cancelled, .failed:
            frame = startingFrame
            isInteracting = false
            onFrameCommitted?(frame)
        default:
            break
        }
    }

    @objc private func resized(_ recognizer: UIPanGestureRecognizer) {
        guard let container = superview,
              let name = recognizer.name,
              let corner = corner(for: name)
        else { return }

        switch recognizer.state {
        case .began:
            isInteracting = true
            startingFrame = frame
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            let translation = recognizer.translation(in: container)
            frame = resizedFrame(from: startingFrame, corner: corner, translation: translation)
            onFrameChanged?(frame)
        case .ended:
            isInteracting = false
            onFrameCommitted?(frame)
        case .cancelled, .failed:
            frame = startingFrame
            isInteracting = false
            onFrameCommitted?(frame)
        default:
            break
        }
    }

    private func clampedMovedFrame(_ proposed: CGRect) -> CGRect {
        guard !allowedFrame.isEmpty else { return proposed }
        let width = min(proposed.width, allowedFrame.width)
        let height = min(proposed.height, allowedFrame.height)
        let x = min(max(proposed.minX, allowedFrame.minX), allowedFrame.maxX - width)
        let y = min(max(proposed.minY, allowedFrame.minY), allowedFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func resizedFrame(
        from initial: CGRect,
        corner: Corner,
        translation: CGPoint
    ) -> CGRect {
        var minX = initial.minX
        var maxX = initial.maxX
        var minY = initial.minY
        var maxY = initial.maxY
        let minimumWidth = min(minimumSide, initial.width)
        let minimumHeight = min(minimumSide, initial.height)

        if corner.isLeft {
            minX = min(max(initial.minX + translation.x, allowedFrame.minX), maxX - minimumWidth)
        } else {
            maxX = max(min(initial.maxX + translation.x, allowedFrame.maxX), minX + minimumWidth)
        }
        if corner.isTop {
            minY = min(max(initial.minY + translation.y, allowedFrame.minY), maxY - minimumHeight)
        } else {
            maxY = max(min(initial.maxY + translation.y, allowedFrame.maxY), minY + minimumHeight)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func gestureName(for corner: Corner) -> String {
        switch corner {
        case .topLeft: "book-region-top-left"
        case .topRight: "book-region-top-right"
        case .bottomLeft: "book-region-bottom-left"
        case .bottomRight: "book-region-bottom-right"
        }
    }

    private func corner(for name: String) -> Corner? {
        Corner.allCases.first { gestureName(for: $0) == name }
    }

    private func accessibilityLabel(for corner: Corner) -> String {
        switch corner {
        case .topLeft: "Auswahl oben links anpassen"
        case .topRight: "Auswahl oben rechts anpassen"
        case .bottomLeft: "Auswahl unten links anpassen"
        case .bottomRight: "Auswahl unten rechts anpassen"
        }
    }

    @objc private func clearSelection() -> Bool {
        onClear?()
        return true
    }
}

/// Keeps a 44-point native touch target while drawing only the compact handle
/// users expect at the corner of a crop or selection rectangle.
private final class BookRegionHandleView: UIView {
    private let dot = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        backgroundColor = .clear
        dot.fillColor = UIColor.systemBlue.cgColor
        dot.strokeColor = UIColor.white.cgColor
        dot.lineWidth = 2
        layer.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = bounds
        dot.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 14, dy: 14)).cgPath
    }
}

private extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}
