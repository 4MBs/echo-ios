import PDFKit
import SwiftUI

/// One book, presented like the web reader the schoolbooks come from: pages
/// fill the screen, and a bottom bar carries page navigation (‹ 2 – 3 ›) plus
/// the one-page / two-page switcher. The first open downloads the PDF from
/// the server once; after that the persistent on-device copy opens instantly.
struct BookReaderView: View {
    let api: BackendAPI
    let book: BackendAPI.Book

    private enum Phase: Equatable {
        case downloading(Double)
        case ready(URL)
        case failed(String)
    }

    @State private var phase: Phase?

    var body: some View {
        Group {
            switch phase {
            case .none, .downloading:
                downloadProgress
            case .ready(let url):
                PDFReader(url: url)
            case .failed(let message):
                ErrorState(message: message) { await open() }
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
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The reader itself: a PDFKit page view with the control bar underneath.
private struct PDFReader: View {
    let url: URL

    @State private var twoUp = true
    @State private var currentPage = 1
    @State private var pageCount = 0
    @State private var proxy = PDFViewProxy()
    @FocusState private var pageFieldFocused: Bool

    var body: some View {
        PDFKitView(
            url: url,
            twoUp: twoUp,
            proxy: proxy,
            currentPage: $currentPage,
            pageCount: $pageCount
        )
            .id(twoUp)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    modeToggle
                    Spacer()
                    pageControls
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Öffnen") {
                        proxy.go(toPage: currentPage)
                        pageFieldFocused = false
                    }
                }
            }
    }

    /// Previous/next buttons plus an editable current-page field.
    private var pageControls: some View {
        HStack(spacing: 12) {
            Button {
                proxy.pdfView?.goToPreviousPage(nil)
            } label: {
                Image(systemName: "arrow.left")
            }
            .accessibilityLabel("Vorherige Seite")

            HStack(spacing: 4) {
                TextField("Seite", value: $currentPage, format: .number)
                    .multilineTextAlignment(.trailing)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(width: 44)
                    .keyboardType(.numberPad)
                    .focused($pageFieldFocused)
                    .submitLabel(.go)
                    .onSubmit { proxy.go(toPage: currentPage) }
                    .accessibilityLabel("Seitennummer")

                Text("/ \(pageCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())

            Button {
                proxy.pdfView?.goToNextPage(nil)
            } label: {
                Image(systemName: "arrow.right")
            }
            .accessibilityLabel("Nächste Seite")
        }
        .buttonStyle(.glass)
    }

    /// A compact native menu keeps the toolbar quiet while making both layouts
    /// explicit when opened.
    private var modeToggle: some View {
        Menu {
            Button {
                twoUp = false
            } label: {
                Label("Einzelseite", systemImage: "rectangle.portrait")
            }

            Button {
                twoUp = true
            } label: {
                Label("Doppelseite", systemImage: "rectangle.portrait.on.rectangle.portrait")
            }
        } label: {
            Image(systemName: twoUp ? "rectangle.portrait.on.rectangle.portrait" : "rectangle.portrait")
        }
        .accessibilityLabel("Seitendarstellung")
    }
}

/// Bridge so the SwiftUI control bar can drive the UIKit PDFView (which only
/// exists once makeUIView has run).
private final class PDFViewProxy {
    weak var pdfView: PDFView?

    func go(toPage number: Int) {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        let index = min(max(number - 1, 0), document.pageCount - 1)
        if let page = document.page(at: index) { pdfView.go(to: page) }
    }
}

/// PDFKit wrapper: horizontal page-curl navigation, auto-scaled pages, and
/// book layout in two-page mode (cover alone, then 2–3, 4–5 … — matching the
/// printed page numbers).
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let twoUp: Bool
    let proxy: PDFViewProxy
    @Binding var currentPage: Int
    @Binding var pageCount: Int

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        proxy.pdfView = pdfView
        pdfView.autoScales = true
        pdfView.displayDirection = .horizontal
        pdfView.displaysAsBook = twoUp
        pdfView.displayMode = twoUp ? .twoUp : .singlePage
        pdfView.usePageViewController(true, withViewOptions: [
            UIPageViewController.OptionsKey.interPageSpacing: 12,
        ])
        pdfView.document = PDFDocument(url: url)
        if let page = pdfView.document?.page(at: max(currentPage - 1, 0)) {
            pdfView.go(to: page)
        }
        context.coordinator.observe(pdfView)
        DispatchQueue.main.async { updatePageState(pdfView) }
        return pdfView
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator { view in
            updatePageState(view)
        }
    }

    private func updatePageState(_ view: PDFView) {
        guard let document = view.document else { return }
        pageCount = document.pageCount
        let visible = view.visiblePages.map { document.index(for: $0) + 1 }
        if let first = visible.min() { currentPage = first }
    }

    final class Coordinator {
        private let onPageChange: (PDFView) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onPageChange: @escaping (PDFView) -> Void) {
            self.onPageChange = onPageChange
        }

        func observe(_ view: PDFView) {
            guard observers.isEmpty else { return }
            let names: [Notification.Name] = [.PDFViewPageChanged, .PDFViewVisiblePagesChanged, .PDFViewDocumentChanged]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: view, queue: .main
                ) { [weak view, onPageChange] _ in
                    guard let view else { return }
                    onPageChange(view)
                })
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
