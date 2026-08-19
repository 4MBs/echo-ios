import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var books: [BackendAPI.Book] = []
    /// Which books are already on the iPad. `nil` until the disk has actually
    /// been read: "not looked at yet" is not the same answer as "not there".
    @State private var downloadedBookIDs: Set<String>?
    @State private var loading = true
    @State private var loadError: Error?

    private var api: BackendAPI { model.api }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Bibliothek")
        }
        .task { await load() }
        // Which books are on the iPad is a question for the file system and
        // not for the server, so it is asked here rather than at the end of
        // `load()` — see `refreshDownloadedBooks()`.
        .task(id: books) { await refreshDownloadedBooks() }
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

    /// Every cover stays a navigation target, and the route is owned by the
    /// link rather than by a `navigationDestination` on the shelf.
    ///
    /// Both halves matter, and both were paid for. A destination declared on
    /// `content` lives on whichever branch of that `if` is on screen, so a
    /// refresh that briefly empties the shelf tears the route down under an
    /// open book — the reader pops and, worse, taps on the covers stop doing
    /// anything at all, because no destination is registered for the type any
    /// more. Nothing short of relaunching brings it back.
    ///
    /// And `disabled` from a shared connectivity flag strands the whole shelf:
    /// `Connectivity` goes offline the moment any one request times out, so a
    /// single failed call elsewhere in the app makes every un-downloaded book
    /// untappable. A book that cannot be fetched is better off opening a reader
    /// that says so and offers to try again — which is what it already does.
    @ViewBuilder private func shelfItem(_ book: BackendAPI.Book) -> some View {
        // Only a finished scan may dim a cover. Until one has finished the
        // book is shown as being here: telling a student to download a book
        // that is already on their iPad is the mistake they see, while the
        // opposite one costs a tap and a reader that explains itself.
        let missing = downloadedBookIDs?.contains(book.id) == false
        let needsConnection = missing && !model.connectivity.isOnline
        NavigationLink {
            // The destination owns the exact book that was tapped, so a shelf
            // refresh can replace `books` while a large PDF is opening without
            // invalidating the active route.
            BookReaderView(api: api, book: book) {
                downloadedBookIDs = (downloadedBookIDs ?? []).union([book.id])
            }
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

    /// File-system probes do not belong in `body`: a split-view resize can
    /// redraw every shelf tile many times per second. Scan once off the main
    /// actor, then let all redraws use this in-memory set.
    ///
    /// The scan follows the shelf's contents and nothing else. Sequenced
    /// after the list request instead, it could only answer once that request
    /// had — and away from the server `/library` does not fail quickly: the
    /// address is a VPN one, so the packets leave and nothing comes back
    /// until the hundred-second timeout gives up. For all of that time the
    /// shelf knew nothing about the iPad's own files and offered a download
    /// for every book already on it — each of which then opened instantly
    /// from disk when it was tapped.
    private func refreshDownloadedBooks() async {
        let snapshot = books
        // There is nothing to answer yet, and answering "none of them" would
        // be read as "none of them are downloaded".
        guard !snapshot.isEmpty else { return }
        let available = await Task.detached(priority: .utility) {
            Set(snapshot.compactMap { book in
                BackendAPI.cachedBook(id: book.id) == nil ? nil : book.id
            })
        }.value
        guard !Task.isCancelled else { return }
        downloadedBookIDs = available
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
            if let stored = await Self.cachedImage(key: key) {
                image = stored.image
                return
            }
            guard let data = try? await api.bookCover(book), !Task.isCancelled else { return }
            let loaded = await Task.detached(priority: .utility) { () -> LoadedCoverImage? in
                OfflineCache.saveData(data, as: key)
                guard let image = Self.decode(data) else { return nil }
                return LoadedCoverImage(image: image)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded?.image
        }
    }

    private static func cachedImage(key: String) async -> LoadedCoverImage? {
        await Task.detached(priority: .utility) { () -> LoadedCoverImage? in
            guard let data = OfflineCache.loadData(key: key), let image = decode(data) else {
                return nil
            }
            return LoadedCoverImage(image: image)
        }.value
    }

    /// `preparingForDisplay` performs decompression on the worker rather than
    /// on the first animation frame that happens to draw the cover.
    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = UIImage(data: data) else { return nil }
        return source.preparingForDisplay() ?? source
    }
}

/// UIKit images are immutable for this use. The wrapper makes the deliberate
/// background decode boundary explicit to Swift concurrency.
private struct LoadedCoverImage: @unchecked Sendable {
    let image: UIImage
}
