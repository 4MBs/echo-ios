import Foundation
import ZIPFoundation

struct LocalNotePage: Codable, Sendable, Equatable {
    var title: String
    var text: String
    var wallTimeMs: Double?
    var sourceId: String?
    var warning: String?

    enum CodingKeys: String, CodingKey {
        case title, text, warning
        case wallTimeMs = "wall_time_ms"
        case sourceId = "source_id"
    }
}

struct GoodnotesLocalDocument: Sendable {
    var pages: [LocalNotePage]
    var thumbnail: Data?
    var exactTypedLines: [String]
}

enum GoodnotesLocalParser {
    private static let maxEntries = 20000
    private static let maxMemberBytes = 64 * 1024 * 1024
    private static let maxArchiveBytes = 256 * 1024 * 1024

    enum ParserError: LocalizedError {
        case invalidDocument
        case unsafeArchive
        case malformedData

        var errorDescription: String? {
            switch self {
            case .invalidDocument:
                "Die Datei ist kein unterstütztes Goodnotes-Notizbuch."
            case .unsafeArchive:
                "Das Goodnotes-Notizbuch enthält unsichere oder zu große Dateien."
            case .malformedData:
                "Die Goodnotes-Daten sind beschädigt oder unvollständig."
            }
        }
    }

    private enum ProtobufValue {
        case varint(UInt64)
        case fixed64(Double)
        case bytes(Data)
        case fixed32(Float)
    }

    private struct ProtobufField {
        let number: Int
        let wire: Int
        let value: ProtobufValue
    }

    private struct NoteObject {
        let id: String
        let sequence: Int
        let kind: Int
        let payload: Data
    }

    private enum RowKind {
        case typed
        case handwriting
    }

    private struct TextRow {
        var y: Float
        var x: Float
        var order: Int
        var text: String
        var kind: RowKind
    }

    static func inspect(data: Data, filename: String) throws -> GoodnotesLocalDocument {
        let archive = try Archive(data: data, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= maxEntries else { throw ParserError.unsafeArchive }

        var totalSize: UInt64 = 0
        var entriesByPath: [String: Entry] = [:]
        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !components.contains(".."),
                  entry.uncompressedSize <= UInt64(maxMemberBytes)
            else { throw ParserError.unsafeArchive }
            totalSize += entry.uncompressedSize
            guard totalSize <= UInt64(maxArchiveBytes) else { throw ParserError.unsafeArchive }
            entriesByPath[entry.path] = entry
        }

        guard entriesByPath["index.events.pb"] != nil,
              entriesByPath.keys.contains(where: { $0.hasPrefix("notes/") })
        else { throw ParserError.invalidDocument }

        func member(_ path: String) throws -> Data {
            guard let entry = entriesByPath[path], entry.type == .file else {
                throw ParserError.malformedData
            }
            var output = Data()
            output.reserveCapacity(Int(entry.uncompressedSize))
            try archive.extract(entry) { chunk in
                guard output.count + chunk.count <= maxMemberBytes else {
                    throw ParserError.unsafeArchive
                }
                output.append(chunk)
            }
            return output
        }

        let events = (try? member("index.events.pb")).map(parseEvents)
            ?? (nil, [:], [:])
        var noteIndex = (try? member("index.notes.pb")).map(parseIndex) ?? []
        if noteIndex.isEmpty {
            noteIndex = entriesByPath.keys
                .filter { $0.hasPrefix("notes/") }
                .sorted()
                .map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }
        }
        let searchIndex = Dictionary(
            uniqueKeysWithValues: (try? member("index.search.pb")).map(parseIndex) ?? []
        )

        var pages: [LocalNotePage] = []
        var allExactTypedLines: [String] = []
        let documentName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent

        for (zeroBasedIndex, item) in noteIndex.enumerated() {
            let (pageId, notePath) = item
            guard let noteData = try? member(notePath) else { continue }
            let objects = parseObjects(noteData)
            guard !objects.isEmpty else { continue }

            let typedRows = objects.compactMap(typedTextRow)
            allExactTypedLines.append(contentsOf: typedRows.flatMap { splitLines($0.text) })
            let searchPath = searchIndex[pageId] ?? "search/\(pageId)"
            var warning: String?
            var rows: [TextRow] = []
            var recognizedStrokeIds = Set<String>()
            var searchRevision: Int?

            if let searchData = try? member(searchPath), !searchData.isEmpty {
                let parsed = parseSearch(searchData)
                rows = parsed.rows
                recognizedStrokeIds = parsed.strokeIds
                searchRevision = parsed.revision
                if let expected = events.2[pageId], searchRevision != expected {
                    warning = "Seite \(zeroBasedIndex + 1): Der Goodnotes-Suchindex ist nicht auf dem neuesten Stand."
                }
            }

            // Type-35 objects contain the original attributed text plus its
            // actual page transform. They are authoritative for typed text.
            // Replace fuzzy/search copies in place and insert missing objects
            // at their real coordinates instead of appending them at the end.
            for typed in typedRows {
                if let match = rows.firstIndex(where: {
                    $0.kind == .typed && normalized($0.text) == normalized(typed.text)
                }) {
                    rows[match] = typed
                } else {
                    rows.append(typed)
                }
            }

            let strokeCount = objects.filter { $0.kind == 24 }.count
            if strokeCount > 0, recognizedStrokeIds.isEmpty {
                warning = "Seite \(zeroBasedIndex + 1): Goodnotes hat keine Handschriftenerkennung exportiert; "
                    + "Echo versucht lokale Apple-Vision-Erkennung."
            }
            if rows.isEmpty, strokeCount > 0 {
                warning = "Seite \(zeroBasedIndex + 1): Die Handschrift wird lokal aus der Goodnotes-Vorschau gelesen."
            }

            rows.sort(by: readingOrder)
            let text = rows.map(\.text).joined(separator: "\n")
            pages.append(
                LocalNotePage(
                    title: "\(documentName) - Seite \(zeroBasedIndex + 1)",
                    text: text,
                    wallTimeMs: events.1[pageId],
                    sourceId: "\(events.0 ?? "goodnotes"):\(pageId)",
                    warning: warning
                )
            )
        }

        if pages.isEmpty {
            pages = [LocalNotePage(title: documentName, text: "")]
        }
        let thumbnail = try? member("thumbnail.jpg")
        return GoodnotesLocalDocument(
            pages: pages,
            thumbnail: thumbnail,
            exactTypedLines: allExactTypedLines
        )
    }

    // MARK: - Goodnotes protobuf

    private static func parseEvents(_ data: Data) -> (String?, [String: Double], [String: Int]) {
        guard let records = try? delimitedMessages(data) else { return (nil, [:], [:]) }
        var documentId: String?
        var contentTimes: [String: Double] = [:]
        var searchRevisions: [String: Int] = [:]
        for record in records {
            guard let fields = try? protobufFields(record) else { continue }
            let root = messageValue(fields, 1).flatMap(utf8)
            for field in fields where field.number != 1 && field.wire == 2 {
                guard case .bytes(let innerData) = field.value,
                      let inner = try? protobufFields(innerData)
                else { continue }
                if field.number == 30, let root, isUUID(root) { documentId = root }
                let times = plausibleMilliseconds(inner)
                guard let newest = times.max() else { continue }
                if field.number == 102 {
                    let pageId = messageValue(inner, 1).flatMap(utf8) ?? root
                    if let pageId, isUUID(pageId) { contentTimes[pageId] = newest }
                } else if field.number == 105 {
                    let pageId = messageValue(inner, 4).flatMap(utf8) ?? root
                    let revision = inner.compactMap { item -> Int? in
                        guard item.number == 5, case .varint(let value) = item.value else { return nil }
                        return Int(exactly: value)
                    }.first
                    if let pageId, isUUID(pageId), let revision { searchRevisions[pageId] = revision }
                }
            }
        }
        return (documentId, contentTimes, searchRevisions)
    }

    private static func parseIndex(_ data: Data) -> [(String, String)] {
        guard let records = try? delimitedMessages(data) else { return [] }
        return records.compactMap { record in
            guard let fields = try? protobufFields(record),
                  let id = messageValue(fields, 1).flatMap(utf8), isUUID(id),
                  let path = messageValue(fields, 2).flatMap(utf8)
            else { return nil }
            return (id, path)
        }
    }

    private static func parseObjects(_ data: Data) -> [NoteObject] {
        guard let records = try? delimitedMessages(data), records.count.isMultiple(of: 2) else { return [] }
        var objects: [NoteObject] = []
        for index in stride(from: 0, to: records.count, by: 2) {
            guard let fields = try? protobufFields(records[index]),
                  let id = messageValue(fields, 1).flatMap(utf8), isUUID(id)
            else { continue }
            var scalars: [Int: UInt64] = [:]
            for field in fields {
                if case .varint(let value) = field.value { scalars[field.number] = value }
            }
            guard let sequence = scalars[9].flatMap(Int.init(exactly:)),
                  let kind = scalars[16].flatMap(Int.init(exactly:))
            else { continue }
            objects.append(NoteObject(id: id, sequence: sequence, kind: kind, payload: records[index + 1]))
        }
        return objects.sorted { $0.sequence < $1.sequence }
    }

    private static func typedTextRow(_ object: NoteObject) -> TextRow? {
        guard object.kind == 35, let text = textObject(object.payload) else { return nil }
        var x = Float.infinity
        var y = Float.infinity
        if let root = try? protobufFields(object.payload),
           let modelData = messageValue(root, 21),
           let model = try? protobufFields(modelData),
           let transformData = messageValue(model, 20),
           let transform = try? protobufFields(transformData),
           let originData = messageValue(transform, 1),
           let origin = point(originData) {
            x = origin.0
            y = origin.1
        }
        return TextRow(y: y, x: x, order: object.sequence, text: text, kind: .typed)
    }

    private static func parseSearch(_ data: Data) -> (rows: [TextRow], strokeIds: Set<String>, revision: Int?) {
        guard let fields = try? protobufFields(data) else { return ([], [], nil) }
        // Preserve nil entries until after zipping. Goodnotes' field-3 and
        // field-4 arrays are positional peers. Dropping an undecodable text
        // first shifts every later string onto the wrong bounding box.
        let plain: [String?] = fields.compactMap { field in
            guard field.number == 3, case .bytes(let value) = field.value else { return nil }
            return .some(utf8(value))
        }
        let boxes: [Data] = fields.compactMap { field in
            guard field.number == 4, case .bytes(let value) = field.value else { return nil }
            return value
        }
        var rows: [TextRow] = []
        for index in 0 ..< min(plain.count, boxes.count) {
            guard let text = plain[index]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                continue
            }
            let position = searchPosition(boxes[index], handwriting: false)
            rows.append(TextRow(y: position.1, x: position.0, order: index, text: text, kind: .typed))
        }

        var strokeIds = Set<String>()
        var handwritingOrder = rows.count
        for field in fields where field.number == 6 {
            guard case .bytes(let groupData) = field.value,
                  let group = try? protobufFields(groupData)
            else { continue }
            let candidate = group.compactMap { item -> String? in
                guard item.number == 3, case .bytes(let value) = item.value else { return nil }
                return utf8(value)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.first(where: { !$0.isEmpty })
            for item in group where item.number == 7 {
                guard case .bytes(let strokeData) = item.value,
                      let stroke = try? protobufFields(strokeData),
                      let id = messageValue(stroke, 1).flatMap(utf8), isUUID(id)
                else { continue }
                strokeIds.insert(id)
            }
            if let candidate {
                let position = searchPosition(groupData, handwriting: true)
                rows.append(
                    TextRow(
                        y: position.1,
                        x: position.0,
                        order: handwritingOrder,
                        text: candidate,
                        kind: .handwriting
                    )
                )
                handwritingOrder += 1
            }
        }
        let revision = fields.compactMap { field -> Int? in
            guard field.number == 12, case .varint(let value) = field.value else { return nil }
            return Int(exactly: value)
        }.first
        return (rows, strokeIds, revision)
    }

    private static func textObject(_ payload: Data) -> String? {
        let markers = [Data("bv41".utf8), Data("bv4-".utf8)].compactMap { payload.range(of: $0)?.lowerBound }
        guard let marker = markers.min(), let decoded = try? appleLZ4(Data(payload[marker...])) else { return nil }
        guard let fields = try? protobufFields(decoded) else { return nil }
        var chunks: [String] = []
        for field in fields where field.number == 1 {
            guard case .bytes(let runData) = field.value,
                  let run = try? protobufFields(runData),
                  let raw = messageValue(run, 1),
                  let text = String(data: raw, encoding: .utf8), isReadable(text)
            else { continue }
            chunks.append(text)
        }
        let result = chunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : splitLines(result).joined(separator: "\n")
    }

    private static func searchPosition(_ data: Data, handwriting: Bool) -> (Float, Float) {
        guard let fields = try? protobufFields(data) else { return (.infinity, .infinity) }
        if handwriting,
           let boundsData = messageValue(fields, 1),
           let bounds = try? protobufFields(boundsData),
           let originData = messageValue(bounds, 1),
           let origin = point(originData) {
            return origin
        }
        if !handwriting,
           let transformData = messageValue(fields, 3),
           let transform = try? protobufFields(transformData) {
            var values: [Int: Float] = [:]
            for field in transform {
                if case .fixed32(let value) = field.value { values[field.number] = value }
            }
            if let x = values[5], let y = values[6] { return (x, y) }
        }
        return (.infinity, .infinity)
    }

    private static func point(_ data: Data) -> (Float, Float)? {
        guard let fields = try? protobufFields(data) else { return nil }
        var values: [Int: Float] = [:]
        for field in fields {
            if case .fixed32(let value) = field.value { values[field.number] = value }
        }
        guard let x = values[1], let y = values[2] else { return nil }
        return (x, y)
    }

    private static func readingOrder(_ lhs: TextRow, _ rhs: TextRow) -> Bool {
        if lhs.y.isInfinite != rhs.y.isInfinite { return !lhs.y.isInfinite }
        let lhsLine = lhs.y.isInfinite ? lhs.y : (lhs.y / 12).rounded()
        let rhsLine = rhs.y.isInfinite ? rhs.y : (rhs.y / 12).rounded()
        if lhsLine != rhsLine { return lhsLine < rhsLine }
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        return lhs.order < rhs.order
    }

    // MARK: - Binary helpers

    private static func protobufFields(_ data: Data) throws -> [ProtobufField] {
        var offset = 0
        var output: [ProtobufField] = []
        while offset < data.count {
            let key = try varint(data, &offset)
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            guard number > 0, [0, 1, 2, 5].contains(wire) else { throw ParserError.malformedData }
            let value: ProtobufValue
            switch wire {
            case 0:
                value = try .varint(varint(data, &offset))
            case 1:
                guard offset + 8 <= data.count else { throw ParserError.malformedData }
                value = .fixed64(Double(bitPattern: littleUInt64(data, offset)))
                offset += 8
            case 2:
                let length = try varint(data, &offset)
                guard length <= UInt64(maxMemberBytes), let count = Int(exactly: length),
                      offset + count <= data.count
                else { throw ParserError.malformedData }
                value = .bytes(Data(data[offset ..< offset + count]))
                offset += count
            case 5:
                guard offset + 4 <= data.count else { throw ParserError.malformedData }
                value = .fixed32(Float(bitPattern: littleUInt32(data, offset)))
                offset += 4
            default:
                throw ParserError.malformedData
            }
            output.append(ProtobufField(number: number, wire: wire, value: value))
        }
        return output
    }

    private static func delimitedMessages(_ data: Data) throws -> [Data] {
        var offset = 0
        var messages: [Data] = []
        while offset < data.count {
            let length = try varint(data, &offset)
            guard length <= UInt64(maxMemberBytes), let count = Int(exactly: length),
                  offset + count <= data.count
            else { throw ParserError.malformedData }
            messages.append(Data(data[offset ..< offset + count]))
            offset += count
        }
        return messages
    }

    private static func varint(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift <= 63 {
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
        throw ParserError.malformedData
    }

    private static func messageValue(_ fields: [ProtobufField], _ number: Int) -> Data? {
        fields.compactMap { field -> Data? in
            guard field.number == number, case .bytes(let value) = field.value else { return nil }
            return value
        }.first
    }

    private static func plausibleMilliseconds(_ fields: [ProtobufField], depth: Int = 0) -> [Double] {
        guard depth < 12 else { return [] }
        var output: [Double] = []
        for field in fields {
            switch field.value {
            case .fixed64(let value) where (1.5e12 ... 2.5e12).contains(value):
                output.append(value)
            case .bytes(let value):
                if let nested = try? protobufFields(value) {
                    output.append(contentsOf: plausibleMilliseconds(nested, depth: depth + 1))
                }
            default:
                break
            }
        }
        return output
    }

    private static func appleLZ4(_ source: Data) throws -> Data {
        var output = Data()
        var offset = 0
        while offset < source.count {
            guard offset + 4 <= source.count else { throw ParserError.malformedData }
            let magic = Data(source[offset ..< offset + 4])
            if magic == Data("bv4$".utf8) { return output }
            let block: Data
            if magic == Data("bv41".utf8) {
                guard offset + 12 <= source.count else { throw ParserError.malformedData }
                let decodedSize = Int(littleUInt32(source, offset + 4))
                let encodedSize = Int(littleUInt32(source, offset + 8))
                offset += 12
                guard decodedSize <= maxMemberBytes, encodedSize <= maxMemberBytes,
                      offset + encodedSize <= source.count
                else { throw ParserError.malformedData }
                block = try lz4Block(Data(source[offset ..< offset + encodedSize]), expectedSize: decodedSize)
                offset += encodedSize
            } else if magic == Data("bv4-".utf8) {
                guard offset + 8 <= source.count else { throw ParserError.malformedData }
                let decodedSize = Int(littleUInt32(source, offset + 4))
                offset += 8
                guard decodedSize <= maxMemberBytes, offset + decodedSize <= source.count else {
                    throw ParserError.malformedData
                }
                block = Data(source[offset ..< offset + decodedSize])
                offset += decodedSize
            } else {
                throw ParserError.malformedData
            }
            guard output.count + block.count <= maxMemberBytes else { throw ParserError.malformedData }
            output.append(block)
        }
        throw ParserError.malformedData
    }

    private static func lz4Block(_ source: Data, expectedSize: Int) throws -> Data {
        var output = [UInt8]()
        output.reserveCapacity(expectedSize)
        var offset = 0
        while offset < source.count {
            let token = source[offset]
            offset += 1
            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                while true {
                    guard offset < source.count else { throw ParserError.malformedData }
                    let ext = Int(source[offset])
                    offset += 1
                    literalLength += ext
                    if ext != 0xFF { break }
                }
            }
            guard offset + literalLength <= source.count,
                  output.count + literalLength <= expectedSize
            else { throw ParserError.malformedData }
            output.append(contentsOf: source[offset ..< offset + literalLength])
            offset += literalLength
            if offset == source.count { break }
            guard offset + 2 <= source.count else { throw ParserError.malformedData }
            let matchOffset = Int(source[offset]) | (Int(source[offset + 1]) << 8)
            offset += 2
            guard matchOffset > 0, matchOffset <= output.count else { throw ParserError.malformedData }
            var matchLength = Int(token & 0x0F)
            if matchLength == 15 {
                while true {
                    guard offset < source.count else { throw ParserError.malformedData }
                    let ext = Int(source[offset])
                    offset += 1
                    matchLength += ext
                    if ext != 0xFF { break }
                }
            }
            matchLength += 4
            guard output.count + matchLength <= expectedSize else { throw ParserError.malformedData }
            let start = output.count - matchOffset
            for index in 0 ..< matchLength {
                output.append(output[start + index])
            }
        }
        guard output.count == expectedSize else { throw ParserError.malformedData }
        return Data(output)
    }

    private static func littleUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func littleUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { value, index in
            value | UInt64(data[offset + index]) << UInt64(index * 8)
        }
    }

    private static func utf8(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty, isReadable(text) else { return nil }
        return text
    }

    private static func isReadable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) || $0.value == 10 || $0.value == 9
        }
    }

    private static func isUUID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func splitLines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
