import Foundation

/// Bibliothek: the schoolbook PDFs live in one folder on the server machine.
/// The app lists them and downloads each book once into its cache — after
/// that it opens instantly and works offline.
extension BackendAPI {
    struct Book: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let fileName: String
        let sizeBytes: Int64

        enum CodingKeys: String, CodingKey {
            case id, title
            case fileName = "file_name"
            case sizeBytes = "size_bytes"
        }
    }

    func listBooks() async throws -> [Book] {
        struct Response: Decodable {
            let books: [Book]
        }
        return try await JSONDecoder().decode(Response.self, from: request("/library")).books
    }

    private static func booksDirectory() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library-books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The already-downloaded copy of a book, if there is one.
    static func cachedBook(id: String) -> URL? {
        let url = booksDirectory().appendingPathComponent("\(id).pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Download a book into the cache, reporting progress (0...1). Books are
    /// large (up to a few hundred MB), so a download task streams straight to
    /// disk instead of going through memory.
    func downloadBook(
        _ book: Book,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if let cached = Self.cachedBook(id: book.id) { return cached }
        var request = try URLRequest(url: url("/library/\(book.id)/file"), timeoutInterval: 3600)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let tmp = try await BookDownloader().download(request, expectedBytes: book.sizeBytes, progress: progress)
        let dest = Self.booksDirectory().appendingPathComponent("\(book.id).pdf")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

/// Streams one authenticated download to a temp file with byte-level progress
/// (the async `URLSession.download(for:)` offers no progress callback).
private final class BookDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var expectedBytes: Int64 = 0

    func download(
        _ request: URLRequest,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        self.progress = progress
        self.expectedBytes = expectedBytes
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // the server sends Content-Length, but fall back to the listed size
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard total > 0 else { return }
        progress?(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // the file at `location` is deleted when this method returns, so any
        // failure to move it aside must fail the download right here
        defer { continuation = nil }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            continuation?.resume(throwing: BackendAPI.APIError(message: "Buch nicht verfügbar (HTTP \(status))."))
            return
        }
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")
            try FileManager.default.moveItem(at: location, to: tmp)
            continuation?.resume(returning: tmp)
        } catch {
            continuation?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
