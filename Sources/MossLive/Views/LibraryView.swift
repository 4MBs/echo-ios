import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var books: [BackendAPI.Book] = []
    @State private var loading = true
    @State private var errorMessage: String?

    private var api: BackendAPI {
        BackendAPI(host: model.settings.serverHost, port: model.settings.serverPort, token: model.settings.authToken)
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

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView("Lade Bücher…").groupedScreen()
        } else if let errorMessage {
            ErrorState(message: errorMessage) { await load() }.groupedScreen()
        } else if books.isEmpty {
            ContentUnavailableView("Keine Bücher", systemImage: "books.vertical", description: Text("Lege PDF-Dateien in den Bibliotheks-Ordner auf dem Server."))
                .groupedScreen()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 24)], spacing: 28) {
                    ForEach(books) { book in
                        NavigationLink(value: book) {
                            BookCover(api: api, book: book)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(book.title)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .groupedScreen()
            .refreshable { await load() }
        }
    }

    private func load() async {
        loading = books.isEmpty
        errorMessage = nil
        do { books = try await api.listBooks() }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }
}

private struct BookCover: View {
    let api: BackendAPI
    let book: BackendAPI.Book
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
        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: book.id) {
            guard let data = try? await api.bookCover(book), !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
    }
}
