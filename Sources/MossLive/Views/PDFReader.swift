import Combine
import PDFKit
import SwiftUI

struct PDFReader: View {
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
                        // Region selection is performed on the book behind the
                        // assistant. Keep that surface interactive even if the
                        // user expanded the sheet before choosing the tool.
                        .presentationBackgroundInteraction(.enabled)
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
            region: $selectedRegion,
            isSelectingRegion: $selectingRegion,
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
        // A medium sheet leaves a useful portion of the page visible. This is
        // also the detent at which the result returns after the drag.
        bookAIDetent = .medium
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            selectingRegion = true
            selectedRegion = nil
        }
        proxy.clearRegionSelection()
        // The button action already runs on the main actor. Install the UIKit
        // overlay immediately so the first drag after activation cannot land
        // on the PDF view during a one-run-loop gap.
        proxy.beginRegionSelection { region in
            bookAIDetent = .medium
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                selectedRegion = region
                selectingRegion = false
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
