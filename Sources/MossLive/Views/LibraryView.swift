import SwiftUI

/// "Bibliothek": the schoolbook shelf. The books are PDFs in one folder on
/// the server machine; tapping one opens it in the reader (downloaded once,
/// then cached on the iPad).
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    @State private var books: [BackendAPI.Book] = []
    @State private var loading = true
    @State private var errorMessage: String?

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Bibliothek")
                .navigationDestination(for: BackendAPI.Book.self) { book in
                    BookReaderView(api: api, book: book)
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Lade Bücher…")
                .groupedScreen()
        } else if let errorMessage {
            ErrorState(message: errorMessage) { await load() }
                .groupedScreen()
        } else if books.isEmpty {
            ContentUnavailableView {
                Label("Keine Bücher", systemImage: "books.vertical")
            } description: {
                Text("Lege PDF-Dateien in den Bibliotheks-Ordner auf dem Server, dann erscheinen sie hier.")
            }
            .groupedScreen()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    ForEach(books) { book in
                        NavigationLink(value: book) {
                            BookCard(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .groupedScreen()
            .refreshable { await load() }
        }
    }

    private func load() async {
        loading = books.isEmpty // pull-to-refresh must not blank the shelf
        errorMessage = nil
        do {
            books = try await api.listBooks()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

/// One shelf tile. Schoolbook file names follow a "Titel - Reihe - Verlag"
/// pattern, so the first segment becomes the headline and the rest the
/// subtitle line.
private struct BookCard: View {
    let book: BackendAPI.Book

    private var parts: (title: String, subtitle: String?) {
        let pieces = book.title.components(separatedBy: " - ")
        guard pieces.count > 1 else { return (book.title, nil) }
        return (pieces[0], pieces.dropFirst().joined(separator: " · "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text(parts.title)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            if let subtitle = parts.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: book.sizeBytes, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if BackendAPI.cachedBook(id: book.id) != nil {
                    Label("Geladen", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .cardSurface()
    }
}
