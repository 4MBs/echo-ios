import Foundation

/// Bibliothek: the schoolbook PDFs live in one folder on the server machine.
/// The app lists them and downloads each book once into persistent app storage
/// on the iPad — after that it opens instantly and works offline.
extension BackendAPI {
    struct Book: Codable, Identifiable, Hashable, Sendable {
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
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library-books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func legacyCachedBook(id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library-books", isDirectory: true)
            .appendingPathComponent("\(id).pdf")
    }

    /// The already-downloaded copy of a book, if there is one.
    static func cachedBook(id: String) -> URL? {
        let url = booksDirectory().appendingPathComponent("\(id).pdf")
        if isUsableBookFile(url) { return url }
        // A zero-byte/interrupted file is not an offline copy. Leaving it in
        // place makes every later open skip the download and spin forever.
        try? FileManager.default.removeItem(at: url)

        // Preserve downloads made by earlier versions, which incorrectly used
        // iOS's purgeable Caches directory.
        let legacy = legacyCachedBook(id: id)
        guard isUsableBookFile(legacy) else {
            try? FileManager.default.removeItem(at: legacy)
            return nil
        }
        do {
            try FileManager.default.moveItem(at: legacy, to: url)
            return url
        } catch {
            // Another cover/link evaluation may have migrated it first.
            return isUsableBookFile(url) ? url : nil
        }
    }

    static func removeCachedBook(id: String) {
        try? FileManager.default.removeItem(at: booksDirectory().appendingPathComponent("\(id).pdf"))
        try? FileManager.default.removeItem(at: legacyCachedBook(id: id))
    }

    static func isUsableBookFile(_ url: URL) -> Bool {
        // URL.resourceValues caches metadata on the URL value. A path checked
        // while an interrupted download is still empty can therefore keep
        // reporting a zero-byte size after the file has been replaced.
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileType = attributes[.type] as? FileAttributeType,
            fileType == .typeRegular,
            let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value > 0
    }

    func bookCover(_ book: Book) async throws -> Data {
        var coverRequest = try URLRequest(url: url("/library/\(book.id)/cover"))
        coverRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        coverRequest.cachePolicy = .returnCacheDataElseLoad
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: coverRequest)
        } catch {
            let mapped = await Self.noteOffline(error)
            throw mapped
        }
        // Custom URLSession paths must restore the same global reachability
        // signal as BackendAPI.request after any real server response.
        await Connectivity.shared.noteReachable()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw APIError(message: "Buchcover nicht verfügbar (HTTP \(status)).")
        }
        return data
    }

    /// Download a book into persistent app storage, reporting progress (0...1). Books are
    /// large (up to a few hundred MB), so a download task streams straight to
    /// disk instead of going through memory.
    func downloadBook(
        _ book: Book,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if let cached = Self.cachedBook(id: book.id) { return cached }
        var request = try URLRequest(url: url("/library/\(book.id)/file"), timeoutInterval: 3600)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let tmp: URL
        do {
            tmp = try await BookDownloader().download(request, expectedBytes: book.sizeBytes, progress: progress)
        } catch {
            let mapped = await Self.noteOffline(error)
            throw mapped
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Task.checkCancellation()
        await Connectivity.shared.noteReachable()
        let dest = Self.booksDirectory().appendingPathComponent("\(book.id).pdf")
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            // Two quick opens can finish the same download together. Keep the
            // first complete copy rather than deleting it so the second can
            // replace it; if no valid winner exists, preserve the real error.
            if let existing = Self.cachedBook(id: book.id) {
                return existing
            }
            throw error
        }
    }
}

/// Streams one authenticated download to a temp file with byte-level progress
/// (the async `URLSession.download(for:)` offers no progress callback).
private final class BookDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var expectedBytes: Int64 = 0
    private var activeSession: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var cancelled = false

    func download(
        _ request: URLRequest,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        lock.withLock {
            self.progress = progress
            self.expectedBytes = expectedBytes
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                let shouldStart = lock.withLock {
                    guard !cancelled else { return false }
                    self.continuation = continuation
                    activeSession = session
                    activeTask = task
                    return true
                }
                if shouldStart {
                    task.resume()
                } else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelDownload()
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
        let state = lock.withLock { (progress, expectedBytes) }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : state.1
        guard total > 0 else { return }
        state.0?(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // the file at `location` is deleted when this method returns, so any
        // failure to move it aside must fail the download right here
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            finish(.failure(BackendAPI.APIError(message: "Buch nicht verfügbar (HTTP \(status)).")))
            return
        }
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")
            try FileManager.default.moveItem(at: location, to: tmp)
            if !finish(.success(tmp)) {
                try? FileManager.default.removeItem(at: tmp)
            }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func cancelDownload() {
        let state = lock.withLock {
            cancelled = true
            return self.takeCompletion()
        }
        guard let state else { return }
        state.task?.cancel()
        state.session?.invalidateAndCancel()
        state.continuation.resume(throwing: CancellationError())
    }

    @discardableResult
    private func finish(_ result: Result<URL, Error>) -> Bool {
        let state = lock.withLock { self.takeCompletion() }
        guard let state else { return false }
        state.session?.finishTasksAndInvalidate()
        state.continuation.resume(with: result)
        return true
    }

    /// Called only while `lock` is held.
    private func takeCompletion() -> (
        continuation: CheckedContinuation<URL, Error>,
        session: URLSession?,
        task: URLSessionDownloadTask?
    )? {
        guard let continuation else { return nil }
        let state = (continuation, activeSession, activeTask)
        self.continuation = nil
        activeSession = nil
        activeTask = nil
        progress = nil
        return state
    }
}
