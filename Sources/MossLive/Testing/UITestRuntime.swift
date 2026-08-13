import Foundation
import UIKit

/// Deterministic fixtures used only when the app is launched by XCUITest.
/// Production launches never enter this code path.
enum UITestRuntime {
    enum Scenario: String {
        case populated
        case empty
        case loading
        case offline
        case unauthorized
        case serverError
        case recording
        case reconnecting
        case longContent
    }

    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-UITesting")
    static let scenario: Scenario = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-UITestScenario"), arguments.indices.contains(index + 1)
        else { return .populated }
        return Scenario(rawValue: arguments[index + 1]) ?? .populated
    }()

    static let requestedTab: AppTab? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-UITestTab"), arguments.indices.contains(index + 1)
        else { return nil }
        return AppTab(rawValue: arguments[index + 1])
    }()

    @MainActor
    static func installFixtures() {
        guard isEnabled else { return }
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        for key in [
            OfflineCache.Key.books,
            OfflineCache.Key.lessons,
            OfflineCache.Key.timetableNow,
            OfflineCache.Key.timetableDay,
            OfflineCache.Key.timetableSubjects,
            OfflineCache.Key.lesson("lesson-1"),
            OfflineCache.Key.lesson("lesson-2"),
            OfflineCache.Key.waveform("lesson-1"),
            OfflineCache.Key.waveform("lesson-2"),
        ] {
            OfflineCache.remove(key: key)
        }
        clearGeneratedFiles()

        switch scenario {
        case .populated, .offline, .recording, .reconnecting, .longContent:
            seedOfflineCache()
            seedBookFiles()
            seedAudioFile()
        case .loading:
            seedBookFiles()
            seedAudioFile()
        case .empty, .unauthorized, .serverError:
            break
        }
    }

    private static func clearGeneratedFiles() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(
            at: applicationSupport.appendingPathComponent("library-books", isDirectory: true)
        )
        try? FileManager.default.removeItem(
            at: caches.appendingPathComponent("lesson-audio", isDirectory: true)
        )
    }

    static func response(path: String, method: String, body: [String: Any]?) async throws -> Data {
        if scenario == .loading {
            try await Task.sleep(for: .seconds(4))
        } else {
            try await Task.sleep(for: .milliseconds(120))
        }
        if path == "/answer" || path.hasSuffix("/ask") {
            try await Task.sleep(for: .milliseconds(4000))
        }
        switch scenario {
        case .offline:
            throw BackendAPI.APIError(message: "Keine Verbindung zum Testserver.", isOffline: true)
        case .unauthorized:
            throw BackendAPI.APIError(message: "Testzugang abgelehnt.", status: 401)
        case .serverError:
            throw BackendAPI.APIError(message: "Deterministischer Testfehler.", status: 500)
        default:
            break
        }

        if scenario == .empty {
            return try emptyResponse(path: path)
        }
        return try populatedResponse(path: path, method: method, body: body)
    }

    static var answerSettings: BackendAPI.AnswerSettings? {
        guard isEnabled, scenario != .serverError, scenario != .unauthorized else { return nil }
        return try? JSONDecoder.camelCase.decode(
            BackendAPI.AnswerSettings.self,
            from: json(answerSettingsObject)
        )
    }

    private static func emptyResponse(path: String) throws -> Data {
        if path == "/sessions" { return try json(["sessions": []]) }
        if path == "/library" { return try json(["books": []]) }
        if path == "/timetable/subjects" { return try json(["subjects": []]) }
        if path == "/timetable/now" {
            return try json(["enabled": false, "current": NSNull(), "next": NSNull()])
        }
        if path == "/timetable/day" { return try json(["enabled": false, "lessons": []]) }
        if path == "/timetable/week" { return try json(["days": []]) }
        if path == "/answer/settings" { return try json(answerSettingsObject) }
        return try json([:])
    }

    private static func populatedResponse(path: String, method: String, body: [String: Any]?) throws -> Data {
        if path == "/sessions" { return try json(sessionsObject) }
        if path == "/library" { return try json(booksObject) }
        if path == "/timetable/subjects" { return try json(subjectsObject) }
        if path == "/timetable/now" { return try json(timetableNowObject) }
        if path == "/timetable/day" { return try json(timetableDayObject) }
        if path == "/timetable/week" { return try json(["days": [timetableDayObject]]) }
        if path == "/answer/settings" { return try json(answerSettingsObject) }
        if path == "/answer" {
            return try json(["ok": true, "text": "Die Testantwort fasst die letzten Sekunden zusammen."])
        }
        if path == "/chat" {
            let question = body?["question"] as? String ?? "Frage"
            return try json(["ok": true, "text": chatAnswer(for: question)])
        }
        if path.hasPrefix("/library/"), path.hasSuffix("/ask") {
            return try json([
                "ok": true,
                "text": "Die markierte Buchseite erklärt den Zusammenhang mit einem reproduzierbaren Beispiel.",
                "citations": [["pdf_page": 2, "note": "Beispiel und Definition"]],
                "pages_read": [1, 2, 3],
            ])
        }
        if path.hasSuffix("/waveform") {
            return try json(["peaks": (0 ..< 160).map { 0.15 + Double($0 % 13) / 16 }])
        }
        if path.hasSuffix("/summarize") {
            return try json(["summary": "Deterministische Zusammenfassung mit **Kernaussage** und Ergebnis."])
        }
        if path.hasSuffix("/notes") {
            return try json(["notes": notesObject])
        }
        if path == "/vocabulary" || path == "/vocabulary/refresh" {
            var terms = vocabularyObject
            if method == "POST", let additions = body?["terms"] as? [String] {
                terms.append(contentsOf: additions.map { term in
                    [
                        "term": term,
                        "source": "manual",
                        "created_at": "2026-08-13T08:02:00Z",
                    ] as [String: Any]
                })
            }
            return try json(["terms": terms])
        }
        if path.hasSuffix("/transcript/history") {
            return try json(transcriptHistoryObject)
        }
        if path.hasSuffix("/transcript") {
            return try json([
                "revision": 3,
                "has_manual_edits": true,
                "segments": lessonSegments,
            ])
        }
        if path.hasSuffix("/transcription") || path.hasSuffix("/retranscribe") {
            return try json(["status": "completed", "offset": 1, "size": 1, "progress": 1.0])
        }
        if path.hasPrefix("/sessions/") && method == "GET" {
            return try json(lessonDetailObject)
        }
        return try json(["ok": true])
    }

    private static func seedOfflineCache() {
        struct SessionEnvelope: Decodable { let sessions: [BackendAPI.LessonInfo] }
        struct BookEnvelope: Decodable { let books: [BackendAPI.Book] }
        struct SubjectEnvelope: Decodable { let subjects: [BackendAPI.SubjectInfo] }
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(SessionEnvelope.self, from: json(sessionsObject)) {
            OfflineCache.save(value.sessions, as: OfflineCache.Key.lessons)
        }
        if let value = try? decoder.decode(BookEnvelope.self, from: json(booksObject)) {
            OfflineCache.save(value.books, as: OfflineCache.Key.books)
        }
        if let value = try? decoder.decode(SubjectEnvelope.self, from: json(subjectsObject)) {
            OfflineCache.save(value.subjects, as: OfflineCache.Key.timetableSubjects)
        }
        if let value = try? decoder.decode(BackendAPI.LessonDetail.self, from: json(lessonDetailObject)) {
            OfflineCache.save(value, as: OfflineCache.Key.lesson("lesson-1"))
        }
        if let value = try? decoder.decode(BackendAPI.TimetableDay.self, from: json(timetableDayObject)) {
            OfflineCache.save(value, as: OfflineCache.Key.timetableDay)
        }
    }

    @MainActor
    private static func seedBookFiles() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library-books", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = makePDF()
        for (index, id) in ["book-1", "book-2"].enumerated() {
            try? pdf.write(to: root.appendingPathComponent("\(id).pdf"), options: .atomic)
            OfflineCache.saveData(makeCover(index: index), as: OfflineCache.Key.cover(id))
        }
    }

    private static func seedAudioFile() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lesson-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? makeWAV().write(to: root.appendingPathComponent("lesson-1.wav"), options: .atomic)
    }

    @MainActor
    private static func makePDF() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1 ... 8 {
                context.beginPage()
                UIColor(hue: CGFloat(page) / 10, saturation: 0.18, brightness: 0.98, alpha: 1).setFill()
                context.fill(bounds)
                let title = "Echo Testbuch · Seite \(page)"
                title.draw(at: CGPoint(x: 54, y: 64), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                    .foregroundColor: UIColor.label,
                ])
                let body = "Deterministischer PDF-Inhalt für Navigation, Zoom, Doppelseite, Auswahl und Buch-KI."
                body.draw(in: CGRect(x: 54, y: 130, width: 504, height: 180), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 18),
                    .foregroundColor: UIColor.darkGray,
                ])
            }
        }
    }

    @MainActor
    private static func makeCover(index: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 500))
        return renderer.pngData { context in
            UIColor(hue: index == 0 ? 0.58 : 0.08, saturation: 0.65, brightness: 0.75, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 500))
            "ECHO\nTESTBUCH \(index + 1)".draw(
                in: CGRect(x: 34, y: 160, width: 292, height: 170),
                withAttributes: [.font: UIFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: UIColor.white]
            )
        }
    }

    private static func makeWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let sampleCount = Int(sampleRate)
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0 ..< sampleCount {
            var sample = Int16(sin(Double(index) * 2 * .pi * 220 / Double(sampleRate)) * 2000).littleEndian
            Swift.withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var data = Data("RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + pcm.count))
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLittleEndian(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private static func chatAnswer(for question: String) -> String {
        let suffix = scenario == .longContent
            ? String(repeating: " Langer Testinhalt prüft Umbruch, Scrollen und Größenänderungen.", count: 20)
            : ""
        return "Antwort auf „\(question.prefix(80))“. **Fett**, normal und reproduzierbar.\(suffix)"
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private extension JSONDecoder {
    static var camelCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

private extension UITestRuntime {
    static let nowMilliseconds: Int64 = 1_775_702_400_000

    static var lessonSegments: [[String: Any]] {
        [
            ["t0": 0.0, "t1": 8.0, "speaker": "Lehrkraft", "text": "Willkommen zur Teststunde."],
            ["t0": 8.0, "t1": 18.0, "speaker": "Schüler", "text": "Wie hängen Ursache und Wirkung zusammen?"],
            ["t0": 18.0, "t1": 35.0, "speaker": "Lehrkraft", "text": "Wir prüfen das an einem klaren Beispiel."],
        ]
    }

    static var sessionsObject: [String: Any] {
        ["sessions": [
            ["id": "lesson-1", "started_at_ms": nowMilliseconds - 3_600_000, "ended_at_ms": nowMilliseconds,
             "segment_count": 3, "speech_seconds": 30.0, "duration_seconds": 3600.0, "has_summary": true,
             "topic": "Ursache und Wirkung", "summary_excerpt": "Ein reproduzierbares Beispiel.",
             "has_audio": true, "title": "Teststunde Mathematik", "subject": "Mathematik",
             "teacher": "Frau Beispiel", "room": "A12"],
            ["id": "lesson-2", "started_at_ms": nowMilliseconds - 86_400_000,
             "ended_at_ms": nowMilliseconds - 82_800_000,
             "segment_count": 2, "speech_seconds": 20.0, "duration_seconds": 3600.0, "has_summary": false,
             "has_audio": false, "title": "Teststunde Biologie", "subject": "Biologie",
             "teacher": "Herr Muster", "room": "B04"],
        ]]
    }

    static let subjectsObject: [String: Any] = ["subjects": [
        ["short": "MAT", "long": "Mathematik", "name": "Mathematik", "teachers": ["Frau Beispiel"]],
        ["short": "BIO", "long": "Biologie", "name": "Biologie", "teachers": ["Herr Muster"]],
        ["short": "PHY", "long": "Physik", "name": "Physik", "teachers": []],
    ]]

    static let booksObject: [String: Any] = ["books": [
        ["id": "book-1", "title": "Echo Testbuch", "file_name": "echo-test.pdf", "size_bytes": 120_000],
        ["id": "book-2", "title": "Sehr langer Testbuchtitel für Kürzung und Layout",
         "file_name": "lang.pdf", "size_bytes": 120_000],
    ]]

    static var lessonDetailObject: [String: Any] {
        ["id": "lesson-1", "started_at_ms": nowMilliseconds - 3_600_000, "ended_at_ms": nowMilliseconds,
         "summary": "Die Stunde erklärt **Ursache und Wirkung** anhand eines Beispiels.",
         "transcript_revision": 2, "has_manual_edits": true, "has_audio": true,
         "title": "Teststunde Mathematik", "subject": "Mathematik", "teacher": "Frau Beispiel",
         "room": "A12", "segments": lessonSegments]
    }

    static var timetableNowObject: [String: Any] {
        ["enabled": true, "current": timetableLesson, "next": timetableLesson]
    }

    static var timetableDayObject: [String: Any] {
        ["enabled": true, "date": ISO8601DateFormatter.day.string(from: Date()), "lessons": [timetableLesson]]
    }

    static var timetableLesson: [String: Any] {
        ["date": ISO8601DateFormatter.day.string(from: Date()), "start": "08:00", "end": "09:00",
         "start_ms": nowMilliseconds - 1_800_000, "end_ms": nowMilliseconds + 1_800_000,
         "subject": "MAT", "subject_long": "Mathematik", "title": "Mathematik",
         "teacher": "Frau Beispiel", "room": "A12", "cancelled": false, "substitution": false,
         "info": "Deterministische Stunde", "type": "LESSON"]
    }

    static let answerSettingsObject: [String: Any] = [
        "provider": "chatgpt", "chatgpt_model": "gpt-5.6-luna", "chatgpt_reasoning_effort": "medium",
        "chatgpt_service_tier": "fast", "reasoning_efforts": ["minimal", "low", "medium", "high", "max"],
        "chatgpt_models": [
            ["id": "gpt-5.6-luna", "label": "GPT-5.6 Luna", "efforts": ["low", "medium", "high"],
             "default_effort": "medium",
             "service_tiers": [["id": "fast", "label": "Fast", "description": "Priorisiert"]]],
            ["id": "gpt-5.6-sol", "label": "GPT-5.6 Sol", "efforts": ["low", "high", "max"],
             "default_effort": "high", "service_tiers": []],
        ],
    ]
    static let notesObject: [[String: Any]] = [[
        "id": "note-1", "session_id": "lesson-1", "offset_seconds": 12.0, "kind": "text",
        "timing_source": "matched", "title": "Tafelbild", "text_content": "Ursache → Wirkung",
        "original_filename": "Notizen.goodnotes", "mime_type": "application/pdf", "has_attachment": false,
        "created_at": "2026-08-13T08:00:00Z", "updated_at": "2026-08-13T08:00:00Z",
    ]]
    static let vocabularyObject: [[String: Any]] = [
        ["term": "Kausalität", "source": "manual", "created_at": "2026-08-13T08:00:00Z"],
        ["term": "Korrelation", "source": "suggested", "created_at": "2026-08-13T08:01:00Z"],
    ]

    static var transcriptHistoryObject: [String: Any] {
        ["current_revision": 2, "has_manual_edits": true, "revisions": [
            ["id": 2, "revision": 2, "created_at": "2026-08-13T08:20:00Z", "reason": "manual_edit"],
            ["id": 1, "revision": 1, "created_at": "2026-08-13T08:00:00Z", "reason": "live"],
        ]]
    }
}

private extension ISO8601DateFormatter {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
