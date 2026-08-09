import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var books: [BackendAPI.Book] = []
    @State private var loading = true
    @State private var loadError: Error?

    private var api: BackendAPI { model.api }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Bibliothek")
        }
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView("Lade Bücher…").groupedScreen()
        } else if books.isEmpty, let loadError {
            ErrorState(loadError) { await load() }.groupedScreen()
        } else if books.isEmpty {
            ContentUnavailableView(
                "Keine Bücher",
                systemImage: "books.vertical",
                description: Text("Lege PDF-Dateien in den Bibliotheks-Ordner auf dem Server.")
            )
            .groupedScreen()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 24)], spacing: 28) {
                    ForEach(books) { book in
                        shelfItem(book)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .groupedScreen()
            .refreshable { await load() }
        }
    }

    /// Every cover remains a navigation target. If a new book cannot be
    /// downloaded, its reader shows a retryable error; disabling the link from
    /// a shared connectivity flag can otherwise strand the entire shelf after
    /// one unrelated request times out.
    @ViewBuilder private func shelfItem(_ book: BackendAPI.Book) -> some View {
        let downloaded = BackendAPI.cachedBook(id: book.id) != nil
        let needsConnection = !downloaded && !model.connectivity.isOnline
        NavigationLink {
            // The destination owns the exact book that was tapped. A shelf
            // refresh can replace `books` while a large PDF is opening, but it
            // must not invalidate the active navigation route.
            BookReaderView(api: api, book: book)
        } label: {
            BookCover(api: api, book: book, unavailable: needsConnection)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(needsConnection ? "\(book.title), Download benötigt" : book.title)
        .accessibilityHint(needsConnection ? "Öffnet den Download mit einer Möglichkeit zum erneuten Versuch" : "")
    }

    private func load() async {
        let key = OfflineCache.Key.books
        if books.isEmpty, let cached = OfflineCache.load([BackendAPI.Book].self, key: key) {
            books = cached
        }
        loading = books.isEmpty
        loadError = nil
        do {
            let fresh = try await api.listBooks()
            books = fresh
            OfflineCache.save(fresh, as: key)
        } catch {
            // A stored shelf beats an error page. The books already on the iPad
            // open perfectly well without the server, and the shelf is how you
            // get to them.
            if books.isEmpty { loadError = error }
        }
        loading = false
    }
}

private struct BookCover: View {
    let api: BackendAPI
    let book: BackendAPI.Book
    var unavailable = false

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    Image(systemName: "book.closed")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .aspectRatio(0.72, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .overlay {
            if unavailable {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.background.opacity(0.55))
                    .overlay {
                        Image(systemName: "arrow.down.circle.dotted")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .shadow(color: .black.opacity(unavailable ? 0.06 : 0.16), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: book.id) {
            // A cover never changes, so one fetch per book is the whole story —
            // and it is what makes the shelf look like itself offline.
            let key = OfflineCache.Key.cover(book.id)
            if let data = OfflineCache.loadData(key: key), let stored = UIImage(data: data) {
                image = stored
                return
            }
            guard let data = try? await api.bookCover(book), !Task.isCancelled else { return }
            OfflineCache.saveData(data, as: key)
            image = UIImage(data: data)
        }
    }
}
