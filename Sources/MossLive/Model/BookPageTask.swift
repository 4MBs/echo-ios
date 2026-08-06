import CoreGraphics
import Foundation

/// One tappable block of a schoolbook page: an exercise, a paragraph, a table.
///
/// The block comes from the server, which read the book once with a
/// layout-aware OCR model (see `BookTaskStore`). The student taps it instead of
/// describing it in the prompt field, which for "Löse Aufgabe 1" is both slower
/// to type and less exact — with a spread on screen, "Aufgabe 1" is ambiguous
/// and the wording is not.
struct BookPageTask: Identifiable, Hashable, Sendable {
    /// The page it is printed on, as a PDF page — the number Buch-KI is told.
    let pdfPage: Int
    /// Its place in that page's reading order, which makes it identifiable
    /// without relying on the wording being unique.
    let index: Int
    /// The model's block kind: "ListItem" is one exercise, "Text" a paragraph,
    /// "Table"/"Caption"/"SectionHeader" what they say.
    let label: String
    /// What the block says, read off the page on the server.
    let text: String
    /// Where it sits, in that page's own coordinate space (PDFKit's: points,
    /// origin at the bottom left).
    let bounds: CGRect

    var id: String { "\(pdfPage)-\(index)" }

    var isExercise: Bool { label == "ListItem" }

    /// The number a numbered exercise carries, when it has one. Used only for
    /// the label on screen — nothing depends on finding it, because the server
    /// already decided this block is one exercise.
    var number: Int? {
        let digits = text.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let value = Int(digits), value >= 1 else {
            return nil
        }
        return value
    }

    /// What the chip in Buch-KI's panel calls it.
    var labelText: String {
        if let number, isExercise { return "Aufgabe \(number)" }
        return isExercise ? "Aufgabe" : "Markierter Text"
    }

    /// The question that goes to the server when this block is sent.
    ///
    /// It carries the wording as well as the number: with two pages on screen
    /// both halves of a spread can have an "Aufgabe 1", and the wording is what
    /// tells them apart. The pages travel beside the question in the request,
    /// so nothing here needs to name a page.
    func question(note: String = "") -> String {
        let wording = Self.shortened(text)
        var lines: [String] = []
        if isExercise {
            lines.append(number.map { "Löse Aufgabe \($0)." } ?? "Löse diese Aufgabe.")
            if !wording.isEmpty {
                lines.append("Die Aufgabenstellung auf der Seite lautet: „\(wording)“")
            }
        } else {
            lines.append("Erkläre diese Stelle auf der Seite:")
            lines.append("„\(wording)“")
        }
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            lines.append(extra)
        }
        return lines.joined(separator: "\n")
    }

    /// One line, and short enough that the server's question limit is never the
    /// thing that fails. The AI reads the real page anyway; this says *which*
    /// block, it does not replace it.
    static func shortened(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > maxWordingCharacters else { return flat }
        return String(flat.prefix(maxWordingCharacters)) + "…"
    }

    static let maxWordingCharacters = 600
}
