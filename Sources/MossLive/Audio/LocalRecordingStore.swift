import AVFoundation
import Foundation
import os

enum LocalRecordingState: String, Codable, Sendable {
    case recording
    case finalizing
    case completed
    case recovered
    case failed
}

struct LocalRecordingManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: UUID
    var state: LocalRecordingState
    let startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    let pcmFilename: String
    var m4aFilename: String?
    let sampleRate: Double
    let channels: Int
    var framesWritten: Int64
    var events: [AudioDiagnosticEvent]
    var error: String?

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(framesWritten) / sampleRate
    }
}

struct LocalRecordingSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let state: LocalRecordingState
    let startedAt: Date
    let durationSeconds: Double
    let url: URL
    let events: [AudioDiagnosticEvent]
    let error: String?
}

enum LocalRecordingStorage {
    static let manifestName = "manifest.json"
    static let pcmName = "safety-recording.caf"
    static let m4aName = "safety-recording.m4a"

    static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("EchoRecordings", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func directory(root: URL, id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func manifestURL(root: URL, id: UUID) -> URL {
        directory(root: root, id: id).appendingPathComponent(manifestName)
    }

    static func save(_ manifest: LocalRecordingManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static func load(from url: URL) throws -> LocalRecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalRecordingManifest.self, from: Data(contentsOf: url))
    }

    static func append(_ event: AudioDiagnosticEvent, to manifestURL: URL) {
        guard var manifest = try? load(from: manifestURL) else { return }
        manifest.events.append(event)
        if manifest.events.count > 300 {
            manifest.events.removeFirst(manifest.events.count - 300)
        }
        manifest.updatedAt = event.date
        try? save(manifest, to: manifestURL)
    }

    static func manifests(root: URL) -> [(URL, LocalRecordingManifest)] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return directories.compactMap { directory in
            let url = directory.appendingPathComponent(manifestName)
            guard let manifest = try? load(from: url) else { return nil }
            return (url, manifest)
        }
        .sorted { $0.1.startedAt > $1.1.startedAt }
    }

    static func summaries(root: URL) -> [LocalRecordingSummary] {
        manifests(root: root).compactMap { manifestURL, manifest in
            let directory = manifestURL.deletingLastPathComponent()
            let candidate = manifest.m4aFilename ?? manifest.pcmFilename
            let audioURL = directory.appendingPathComponent(candidate)
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
            return LocalRecordingSummary(
                id: manifest.id,
                state: manifest.state,
                startedAt: manifest.startedAt,
                durationSeconds: manifest.durationSeconds,
                url: audioURL,
                events: manifest.events,
                error: manifest.error
            )
        }
    }
}

/// Mutable writer confined to AudioCaptureEngine.processingQueue.
final class LocalRecordingWriter {
    let root: URL
    let id: UUID
    private(set) var manifest: LocalRecordingManifest
    private var file: AVAudioFile?
    private var lastCheckpoint = Date.distantPast

    var manifestURL: URL {
        LocalRecordingStorage.manifestURL(root: root, id: id)
    }

    init(root: URL, format: AVAudioFormat, now: Date = .now) throws {
        self.root = root
        id = UUID()
        let directory = LocalRecordingStorage.directory(root: root, id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pcmURL = directory.appendingPathComponent(LocalRecordingStorage.pcmName)
        file = try AVAudioFile(forWriting: pcmURL, settings: format.settings)
        manifest = LocalRecordingManifest(
            version: LocalRecordingManifest.currentVersion,
            id: id,
            state: .recording,
            startedAt: now,
            updatedAt: now,
            pcmFilename: LocalRecordingStorage.pcmName,
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount),
            framesWritten: 0,
            events: [
                AudioDiagnosticEvent(
                    kind: .started,
                    message: "Lokale \(Int(format.sampleRate))-Hz-Sicherheitsaufnahme gestartet",
                    date: now
                ),
            ]
        )
        try checkpoint(force: true, now: now)
    }

    func write(_ buffer: AVAudioPCMBuffer, now: Date = .now) throws {
        guard let file else { return }
        try file.write(from: buffer)
        manifest.framesWritten += Int64(buffer.frameLength)
        try checkpoint(force: false, now: now)
    }

    func append(_ event: AudioDiagnosticEvent) {
        manifest.events.append(event)
        // A bounded diagnostic history keeps the manifest small during repeated
        // route flapping while retaining everything relevant to the latest run.
        if manifest.events.count > 300 {
            manifest.events.removeFirst(manifest.events.count - 300)
        }
        try? checkpoint(force: true, now: event.date)
    }

    func finish(now: Date = .now) -> URL {
        append(AudioDiagnosticEvent(kind: .stopped, message: "Aufnahme regulär beendet", date: now))
        file?.close()
        file = nil
        manifest.state = .finalizing
        manifest.endedAt = now
        manifest.updatedAt = now
        try? LocalRecordingStorage.save(manifest, to: manifestURL)
        return manifestURL
    }

    func fail(_ message: String, now: Date = .now) {
        file?.close()
        file = nil
        manifest.state = .failed
        manifest.error = message
        manifest.updatedAt = now
        try? LocalRecordingStorage.save(manifest, to: manifestURL)
    }

    private func checkpoint(force: Bool, now: Date) throws {
        guard force || now.timeIntervalSince(lastCheckpoint) >= 1 else { return }
        manifest.updatedAt = now
        try LocalRecordingStorage.save(manifest, to: manifestURL)
        lastCheckpoint = now
    }
}

enum LocalRecordingRecovery {
    private static let log = Logger(subsystem: "com.fourmbs.mosslive", category: "recording-recovery")

    static func finalize(manifestURL: URL, recovered: Bool) async -> LocalRecordingSummary? {
        var manifest: LocalRecordingManifest
        do {
            manifest = try LocalRecordingStorage.load(from: manifestURL)
        } catch {
            log.error("manifest unreadable: \(error.localizedDescription)")
            return nil
        }

        let directory = manifestURL.deletingLastPathComponent()
        let pcmURL = directory.appendingPathComponent(manifest.pcmFilename)
        let m4aURL = directory.appendingPathComponent(LocalRecordingStorage.m4aName)
        guard FileManager.default.fileExists(atPath: pcmURL.path) else {
            if FileManager.default.fileExists(atPath: m4aURL.path) {
                manifest.state = .recovered
                manifest.m4aFilename = LocalRecordingStorage.m4aName
                manifest.error = nil
                manifest.updatedAt = .now
                manifest.events.append(
                    AudioDiagnosticEvent(
                        kind: .recovered,
                        message: "Bereits konvertierte M4A nach einem App-Abbruch wiedergefunden"
                    )
                )
                try? LocalRecordingStorage.save(manifest, to: manifestURL)
                return summary(manifest: manifest, directory: directory)
            }
            manifest.state = .failed
            manifest.error = "PCM-Sicherheitsaufnahme fehlt"
            manifest.updatedAt = .now
            try? LocalRecordingStorage.save(manifest, to: manifestURL)
            return nil
        }

        manifest.state = .finalizing
        manifest.error = nil
        manifest.updatedAt = .now
        if let source = try? AVAudioFile(forReading: pcmURL) {
            manifest.framesWritten = max(manifest.framesWritten, source.length)
        }
        try? LocalRecordingStorage.save(manifest, to: manifestURL)
        try? FileManager.default.removeItem(at: m4aURL)

        do {
            let asset = AVURLAsset(url: pcmURL)
            guard let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw ExportError.unavailable
            }
            try await exporter.export(to: m4aURL, as: .m4a)
            manifest.state = recovered ? .recovered : .completed
            manifest.m4aFilename = LocalRecordingStorage.m4aName
            manifest.error = nil
            manifest.updatedAt = .now
            if recovered {
                manifest.events.append(
                    AudioDiagnosticEvent(
                        kind: .recovered,
                        message: "Nach einem App-Abbruch als M4A wiederhergestellt"
                    )
                )
            }
            try LocalRecordingStorage.save(manifest, to: manifestURL)
            // The manifest points at a complete M4A before the source is
            // removed. A crash between these operations therefore leaves two
            // valid files, never a manifest whose only valid source is gone.
            try? FileManager.default.removeItem(at: pcmURL)
            return summary(manifest: manifest, directory: directory)
        } catch {
            manifest.state = .failed
            manifest.error = "M4A-Konvertierung fehlgeschlagen: \(error.localizedDescription)"
            manifest.updatedAt = .now
            try? LocalRecordingStorage.save(manifest, to: manifestURL)
            log.error("M4A export failed: \(error.localizedDescription)")
            return summary(manifest: manifest, directory: directory)
        }
    }

    static func recoverPending(root: URL) async -> [LocalRecordingSummary] {
        let pending = LocalRecordingStorage.manifests(root: root).filter {
            $0.1.state == .recording || $0.1.state == .finalizing
        }
        var recovered: [LocalRecordingSummary] = []
        for (manifestURL, _) in pending {
            if let summary = await finalize(manifestURL: manifestURL, recovered: true) {
                recovered.append(summary)
            }
        }
        return recovered
    }

    private static func summary(
        manifest: LocalRecordingManifest,
        directory: URL
    ) -> LocalRecordingSummary {
        let filename = manifest.m4aFilename ?? manifest.pcmFilename
        return LocalRecordingSummary(
            id: manifest.id,
            state: manifest.state,
            startedAt: manifest.startedAt,
            durationSeconds: manifest.durationSeconds,
            url: directory.appendingPathComponent(filename),
            events: manifest.events,
            error: manifest.error
        )
    }

    enum ExportError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Auf diesem Gerät steht kein M4A-Exporter zur Verfügung."
        }
    }
}
