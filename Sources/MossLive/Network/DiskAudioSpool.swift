import Foundation

/// A length-prefixed, disk-backed FIFO. Appends come from the audio conversion
/// queue; reads/acks come from WebSocketClient's actor. A lock makes those two
/// short file operations safe without retaining audio frames in RAM.
final class DiskAudioSpool: @unchecked Sendable {
    struct Status: Equatable, Sendable {
        let pendingFrames: Int
        let pendingBytes: Int64
    }

    enum SpoolError: LocalizedError {
        case notStarted
        case corruptRecord

        var errorDescription: String? {
            switch self {
            case .notStarted: "Audio-Spool wurde nicht gestartet."
            case .corruptRecord: "Audio-Spool enthält einen unvollständigen Datensatz."
            }
        }
    }

    private let lock = NSLock()
    private let root: URL
    private var fileURL: URL?
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?
    private var readOffset: UInt64 = 0
    private var writeOffset: UInt64 = 0
    private var pendingFrames = 0
    private var framesSinceSync = 0

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.root = caches.appendingPathComponent("EchoAudioSpool", isDirectory: true)
        }
    }

    /// Starts a fresh recording and reports frames left by an unclean previous
    /// run. Those frames cannot safely enter a new server sequence space.
    func begin(id: UUID) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var orphaned = pendingFrames
        let activeURL = fileURL
        closeLocked()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staleFiles = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for stale in staleFiles where stale.pathExtension == "spool" {
            if stale != activeURL {
                orphaned += Self.recordCount(in: stale)
            }
            try? FileManager.default.removeItem(at: stale)
        }
        let url = root.appendingPathComponent("\(id.uuidString).spool")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        fileURL = url
        writeHandle = try FileHandle(forWritingTo: url)
        readHandle = try FileHandle(forReadingFrom: url)
        readOffset = 0
        writeOffset = 0
        pendingFrames = 0
        return orphaned
    }

    func append(_ frame: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let writeHandle else { throw SpoolError.notStarted }
        var length = UInt32(frame.count).bigEndian
        var record = Data(capacity: 4 + frame.count)
        withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }
        record.append(frame)
        try writeHandle.seek(toOffset: writeOffset)
        try writeHandle.write(contentsOf: record)
        writeOffset += UInt64(record.count)
        pendingFrames += 1
        framesSinceSync += 1
        if framesSinceSync >= 50 {
            try writeHandle.synchronize()
            framesSinceSync = 0
        }
    }

    /// Returns the oldest frame without consuming it.
    func peek() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let readHandle else { throw SpoolError.notStarted }
        guard pendingFrames > 0 else { return nil }
        try readHandle.seek(toOffset: readOffset)
        guard let header = try readHandle.read(upToCount: 4), header.count == 4 else {
            throw SpoolError.corruptRecord
        }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 1_048_576,
              let frame = try readHandle.read(upToCount: Int(length)),
              frame.count == Int(length)
        else {
            throw SpoolError.corruptRecord
        }
        return frame
    }

    func acknowledge(_ frame: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingFrames > 0 else { return }
        readOffset += UInt64(4 + frame.count)
        pendingFrames -= 1
    }

    func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        return Status(
            pendingFrames: pendingFrames,
            pendingBytes: Int64(max(0, writeOffset - readOffset))
        )
    }

    /// A new server session cannot consume packets encoded for the old sequence
    /// space. Replace the spool atomically and return the discarded frame count.
    func discardAndRestart(id: UUID) throws -> Int {
        try begin(id: id)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        let shouldDelete = pendingFrames == 0
        let url = fileURL
        let unreadOffset = readOffset
        try? writeHandle?.synchronize()
        closeLocked()
        if shouldDelete, let url {
            try? FileManager.default.removeItem(at: url)
        } else if let url, unreadOffset > 0 {
            Self.keepSuffix(of: url, from: unreadOffset)
        }
    }

    private func closeLocked() {
        try? writeHandle?.close()
        try? readHandle?.close()
        writeHandle = nil
        readHandle = nil
        readOffset = 0
        writeOffset = 0
        pendingFrames = 0
        framesSinceSync = 0
        fileURL = nil
    }

    private static func recordCount(in url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var count = 0
        while let header = try? handle.read(upToCount: 4), header.count == 4 {
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= 1_048_576,
                  let payload = try? handle.read(upToCount: Int(length)),
                  payload.count == Int(length)
            else { break }
            count += 1
        }
        return count
    }

    /// Compact only on stop, never in the hot path. Copying in chunks avoids
    /// loading a long classroom outage into memory.
    private static func keepSuffix(of url: URL, from offset: UInt64) {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil),
              let source = try? FileHandle(forReadingFrom: url),
              let destination = try? FileHandle(forWritingTo: temporary)
        else { return }
        defer {
            try? source.close()
            try? destination.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try source.seek(toOffset: offset)
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                try destination.write(contentsOf: chunk)
            }
            try destination.synchronize()
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            return
        }
    }
}
