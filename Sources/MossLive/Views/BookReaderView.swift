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
    @State private var pageLabel = ""
    @State private var proxy = PDFViewProxy()

    var body: some View {
        PDFKitView(url: url, twoUp: twoUp, proxy: proxy, pageLabel: $pageLabel)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    modeToggle
                    Spacer()
                    pageControls
                    Spacer()
                    Color.clear.frame(width: 112, height: 1)
                }
            }
    }

    /// ‹ [2 – 3] › — the same center group as the web reader.
    private var pageControls: some View {
        HStack(spacing: 12) {
            Button {
                proxy.pdfView?.goToPreviousPage(nil)
            } label: {
                Image(systemName: "arrow.left")
            }
            .accessibilityLabel("Vorherige Seite")

            Text(pageLabel)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 64)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Seite \(pageLabel)")

            Button {
                proxy.pdfView?.goToNextPage(nil)
            } label: {
                Image(systemName: "arrow.right")
            }
            .accessibilityLabel("Nächste Seite")
        }
        .buttonStyle(.glass)
    }

    /// Einzelseite / Doppelseite, like the reader's view-mode group.
    private var modeToggle: some View {
        Picker("Seitendarstellung", selection: $twoUp) {
            Image(systemName: "rectangle.portrait").tag(false)
            Image(systemName: "book.pages").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 112)
    }
}

/// Bridge so the SwiftUI control bar can drive the UIKit PDFView (which only
/// exists once makeUIView has run).
private final class PDFViewProxy {
    weak var pdfView: PDFView?
}

/// PDFKit wrapper: horizontal page-curl navigation, auto-scaled pages, and
/// book layout in two-page mode (cover alone, then 2–3, 4–5 … — matching the
/// printed page numbers).
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let twoUp: Bool
    let proxy: PDFViewProxy
    @Binding var pageLabel: String

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        proxy.pdfView = pdfView
        pdfView.autoScales = true
        pdfView.displayDirection = .horizontal
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pdfView.document = PDFDocument(url: url)
        applyMode(pdfView)
        context.coordinator.observe(pdfView)
        return pdfView
    }

    func updateUIView(_ view: PDFView, context: Context) {
        applyMode(view)
    }

    /// Idempotent: updateUIView also runs for unrelated state changes, and
    /// re-setting the display mode would visibly re-layout the page.
    private func applyMode(_ view: PDFView) {
        let mode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        guard view.displayMode != mode || view.displaysAsBook != twoUp else { return }
        let page = view.currentPage
        view.displaysAsBook = twoUp
        view.displayMode = mode
        view.layoutDocumentView()
        view.autoScales = true
        if let page { view.go(to: page) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator { view in
            pageLabel = Self.label(for: view)
        }
    }

    /// "3" in single-page mode, "2 – 3" for a spread.
    private static func label(for view: PDFView) -> String {
        guard let document = view.document else { return "" }
        let numbers = view.visiblePages.map { document.index(for: $0) + 1 }.sorted()
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? "\(first)" : "\(first) – \(last)"
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
