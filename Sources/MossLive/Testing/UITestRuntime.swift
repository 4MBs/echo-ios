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
        /// Offline in the way that hurts: the machine is reachable only over
        /// the VPN, so a request to it is not refused — it leaves and nothing
        /// ever comes back. Every screen still has to be right long before
        /// the timeout gives up.
        case offlineStalled
        case unauthorized
        case serverError
        case recording
        case reconnecting
        case longContent
        /// Reads succeed, every change is refused: the state a student meets
        /// when the server is up but will not accept their edit.
        case writeError
        /// A finished 48 kHz safety recording exists on this device for the
        /// seeded lesson, which is what unlocks manual re-transcription.
        case safetyRecording

        /// Both offline scenarios leave the app in the same place — the server
        /// cannot be reached. They differ only in how long it takes to find out.
        var isOffline: Bool { self == .offline || self == .offlineStalled }
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

    /// Deleting a lesson has to stay deleted: the list is reloaded from the
    /// fake server right after the request, so a purely static fixture would
    /// resurrect it and make a working feature look broken.
    private nonisolated(unsafe) static var deletedSessionIDs: Set<String> = []
    private nonisolated(unsafe) static var deletedNoteIDs: Set<String> = []
    private nonisolated(unsafe) static var deletedLearnCardIDs: Set<String> = []

    @MainActor
    static func installFixtures() {
        guard isEnabled else { return }
        deletedSessionIDs.removeAll()
        deletedNoteIDs.removeAll()
        deletedLearnCardIDs.removeAll()
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        for key in [
            OfflineCache.Key.books,
            OfflineCache.Key.lessons,
            OfflineCache.Key.timetableNow,
            OfflineCache.Key.timetableDay,
            OfflineCache.Key.timetableSubjects,
            OfflineCache.Key.learnOverview,
            OfflineCache.Key.learnCards,
            OfflineCache.Key.lesson("lesson-1"),
            OfflineCache.Key.lesson("lesson-2"),
            OfflineCache.Key.waveform("lesson-1"),
            OfflineCache.Key.waveform("lesson-2"),
        ] {
            OfflineCache.remove(key: key)
        }
        clearGeneratedFiles()

        switch scenario {
        case .safetyRecording:
            seedOfflineCache()
            seedBookFiles()
            seedAudioFile()
            seedSafetyRecording()
        case .populated, .offline, .offlineStalled, .recording, .reconnecting, .longContent, .writeError:
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
        try? FileManager.default.removeItem(
            at: applicationSupport.appendingPathComponent("EchoRecordings", isDirectory: true)
        )
    }

    /// A completed safety recording belonging to the seeded lesson. Only the
    /// manifest and a real file on disk matter here: the reader of this state
    /// asks whether a 48 kHz recording exists and whether it has finished.
    private static func seedSafetyRecording() {
        guard let root = try? LocalRecordingStorage.defaultRoot() else { return }
        let id = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let directory = LocalRecordingStorage.directory(root: root, id: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? makeWAV().write(
            to: directory.appendingPathComponent(LocalRecordingStorage.m4aName),
            options: .atomic
        )
        let startedAt = Date(timeIntervalSince1970: Double(nowMilliseconds - 3_600_000) / 1000)
        let manifest = LocalRecordingManifest(
            version: LocalRecordingManifest.currentVersion,
            id: id,
            serverSessionId: "lesson-1",
            state: .completed,
            startedAt: startedAt,
            updatedAt: startedAt.addingTimeInterval(3600),
            endedAt: startedAt.addingTimeInterval(3600),
            pcmFilename: LocalRecordingStorage.pcmName,
            m4aFilename: LocalRecordingStorage.m4aName,
            sampleRate: 48000,
            channels: 1,
            framesWritten: 48000 * 3600,
            events: [],
            error: nil
        )
        try? LocalRecordingStorage.save(
            manifest,
            to: LocalRecordingStorage.manifestURL(root: root, id: id)
        )
    }

    static func response(path: String, method: String, body: [String: Any]?) async throws -> Data {
        if method == "DELETE", path.hasPrefix("/sessions/") {
            let parts = path.dropFirst("/sessions/".count).split(separator: "/")
            if parts.count == 3, parts[1] == "notes" {
                deletedNoteIDs.insert(String(parts[2]))
            } else if parts.count == 1 {
                deletedSessionIDs.insert(String(parts[0]))
            }
        }
        if method == "DELETE", path.hasPrefix("/learn/cards/") {
            deletedLearnCardIDs.insert(String(path.dropFirst("/learn/cards/".count)))
        }
        if scenario == .loading {
            // Long enough to be seen and asserted, short enough that the suite
            // does not spend its time waiting on purpose.
            try await Task.sleep(for: .milliseconds(1000))
        } else {
            try await Task.sleep(for: .milliseconds(50))
        }
        if scenario == .offlineStalled {
            // Deliberately longer than anything that waits on it: a screen
            // that can only be right once this reply arrives has to fail its
            // test rather than race it.
            try await Task.sleep(for: .seconds(120))
        }
        if path == "/answer" || path.hasSuffix("/ask") {
            try await Task.sleep(for: .milliseconds(300))
        }
        if scenario == .writeError, method != "GET" {
            throw BackendAPI.APIError(message: "Der Testserver lehnt Änderungen ab.", status: 500)
        }
        switch scenario {
        case .offline, .offlineStalled:
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
        if path == "/learn/overview" {
            return try json([
                "due_total": 0, "card_total": 0, "estimated_minutes": 0,
                "mastery": 0.0, "subjects": [], "sessions_with_cards": [],
            ])
        }
        if path == "/learn/plan" {
            return try json([
                "date": "2026-08-14", "requested_minutes": 30,
                "estimated_minutes": 0, "cards": [], "blocks": [],
            ])
        }
        if path == "/learn/cards" { return try json(["cards": []]) }
        return try json([:])
    }

    // One deterministic router intentionally covers every fake backend endpoint.
    // swiftlint:disable:next cyclomatic_complexity
    private static func populatedResponse(path: String, method: String, body: [String: Any]?) throws -> Data {
        if path == "/sessions" { return try json(sessionsObject) }
        if path == "/library" { return try json(booksObject) }
        if path == "/timetable/subjects" { return try json(subjectsObject) }
        if path == "/timetable/now" { return try json(timetableNowObject) }
        if path == "/timetable/day" { return try json(timetableDayObject) }
        if path == "/timetable/week" { return try json(["days": [timetableDayObject]]) }
        if path == "/answer/settings" { return try json(answerSettingsObject) }
        if path == "/learn/overview" { return try json(learnOverviewObject) }
        if path == "/learn/plan" { return try json(learnPlanObject) }
        if path == "/learn/cards" { return try json(["cards": learnCardsObject]) }
        if path == "/learn/evaluate" {
            var reviewed = learnCardsObject[0]
            reviewed["box"] = 2
            reviewed["due_date"] = "2026-08-18"
            reviewed["stability"] = 4.0
            reviewed["reps"] = 1
            return try json([
                "ok": true,
                "evaluation": [
                    "category": "correct",
                    "feedback": "Richtig",
                    "correct_answer": "Chlorophyll absorbiert Lichtenergie.",
                ],
                "card": reviewed,
            ])
        }
        if path == "/learn/generate" { return try json(["ok": true, "cards": learnCardsObject, "cached": false]) }
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
        if path == "/sessions/lesson-2" && method == "GET" {
            return try json(biologyLessonDetailObject)
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
        if let value = try? decoder.decode(BackendAPI.LearnOverview.self, from: json(learnOverviewObject)) {
            OfflineCache.save(value, as: OfflineCache.Key.learnOverview)
        }
        if let value = try? decoder.decode([BackendAPI.LearnCard].self, from: json(learnCardsObject)) {
            OfflineCache.save(value, as: OfflineCache.Key.learnCards)
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
        // Six sentences still wrap, scroll and resize like a long answer, and
        // stream in about ten seconds rather than half a minute.
        let suffix = scenario == .longContent
            ? String(repeating: " Langer Testinhalt prüft Umbruch, Scrollen und Größenänderungen.", count: 6)
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
        ["sessions": allSessions.filter { !deletedSessionIDs.contains($0["id"] as? String ?? "") }]
    }

    static var allSessions: [[String: Any]] {
        [
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
        ]
    }

    // A real timetable is not all short words: "Klassenleitungsstunde" wraps
    // onto a second line in a folder that "Physik" fills half of. The grid has
    // to stay a grid across that, so the fixture carries one of each.
    static let subjectsObject: [String: Any] = ["subjects": [
        ["short": "MAT", "long": "Mathematik", "name": "Mathematik", "teachers": ["Frau Beispiel"]],
        ["short": "BIO", "long": "Biologie", "name": "Biologie", "teachers": ["Herr Muster"]],
        ["short": "PHY", "long": "Physik", "name": "Physik", "teachers": []],
        ["short": "KL", "long": "Klassenleitungsstunde", "name": "Klassenleitungsstunde",
         "teachers": ["Frau Beispiel"]],
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

    static var biologyLessonDetailObject: [String: Any] {
        ["id": "lesson-2", "started_at_ms": nowMilliseconds - 86_400_000,
         "ended_at_ms": nowMilliseconds - 82_800_000,
         "summary": "Die Stunde erklärt Photosynthese und Chlorophyll.",
         "transcript_revision": 1, "has_manual_edits": false, "has_audio": false,
         "title": "Teststunde Biologie", "subject": "Biologie", "teacher": "Herr Muster",
         "room": "B04", "segments": [
             ["t0": 8.0, "t1": 16.0, "speaker": "Lehrkraft", "text": "Chlorophyll absorbiert Lichtenergie."],
             ["t0": 16.0, "t1": 28.0, "speaker": "Lehrkraft", "text": "Diese Energie treibt die Lichtreaktion an."],
         ]]
    }

    static var learnOverviewObject: [String: Any] {
        ["due_total": 2, "card_total": 2, "estimated_minutes": 2, "mastery": 0.42,
         "subjects": [["subject": "Biologie", "due": 2, "total": 2, "mastery": 0.42]],
         "sessions_with_cards": ["lesson-2"]]
    }

    static var learnPlanObject: [String: Any] {
        ["date": "2026-08-14", "requested_minutes": 30, "estimated_minutes": 2,
         "cards": learnCardsObject,
         "blocks": [["subject": "Biologie", "exam_name": NSNull(), "card_count": 2,
                     "estimated_minutes": 2, "reason": "Fällige Wiederholung und Wissenslücken"]]]
    }

    static var learnCardsObject: [[String: Any]] {
        [learnCard(
            id: "learn-1",
            question: "Warum ist Chlorophyll für die Photosynthese wichtig?",
            expected: "Chlorophyll absorbiert Lichtenergie.",
            concept: "Photosynthese",
            startMs: 8000
        ), learnCard(
            id: "learn-2",
            question: "Was treibt die Lichtreaktion an?",
            expected: "Die vom Chlorophyll aufgenommene Lichtenergie.",
            concept: "Lichtreaktion",
            startMs: 16000
        )].filter { card in
            guard let id = card["id"] as? String else { return true }
            return !deletedLearnCardIDs.contains(id)
        }
    }

    static func learnCard(
        id: String,
        question: String,
        expected: String,
        concept: String,
        startMs: Int
    ) -> [String: Any] {
        ["id": id, "session_id": "lesson-2", "subject": "Biologie",
         "lesson_title": "Teststunde Biologie", "question": question, "options": [], "answer": 0,
         "explanation": expected, "kind": "free_text", "expected_answer": expected,
         "concept": concept, "difficulty": 2, "source_label": concept,
         "source_start_ms": startMs, "source_end_ms": NSNull(), "source_revision": 1,
         "box": 0, "due_date": "2026-08-14", "stability": 0.0,
         "difficulty_score": 5.0, "reps": 0, "lapses": 0,
         "sources": [["session_id": "lesson-2", "lesson_title": "Teststunde Biologie",
                      "source_label": concept, "source_start_ms": startMs,
                      "source_end_ms": NSNull(), "transcript_revision": 1]]]
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
        "gemini_model": "gemini-3.6-flash-low",
        "gemini_models": [
            ["id": "gemini-3.6-flash", "label": "Gemini 3.6 Flash",
             "efforts": ["low", "medium", "high"], "default_effort": "low"],
            ["id": "gemini-3.1-pro", "label": "Gemini 3.1 Pro",
             "efforts": ["low", "high"], "default_effort": "low"],
        ],
        "claude_model": "claude-opus-5", "claude_effort": "low", "claude_service_tier": "default",
        "claude_efforts": ["low", "medium", "high", "xhigh", "max"],
        "claude_models": [
            ["id": "", "label": "", "efforts": ["low", "medium", "high", "xhigh", "max"],
             "default_effort": "low", "service_tiers": []],
            ["id": "claude-opus-5", "label": "Claude Opus 5",
             "efforts": ["low", "medium", "high", "xhigh", "max"], "default_effort": "low",
             "service_tiers": [["id": "fast", "label": "Fast", "description": "Erhöhter Verbrauch"]]],
            ["id": "claude-sonnet-5", "label": "Claude Sonnet 5",
             "efforts": ["low", "medium", "high", "xhigh", "max"], "default_effort": "low",
             "service_tiers": []],
            ["id": "claude-haiku-4-5", "label": "Claude Haiku 4.5",
             "efforts": [], "default_effort": "", "service_tiers": []],
        ],
    ]
    static var notesObject: [[String: Any]] {
        allNotes.filter { !deletedNoteIDs.contains($0["id"] as? String ?? "") }
    }

    static let allNotes: [[String: Any]] = [[
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
