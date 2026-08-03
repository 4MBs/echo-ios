import CoreGraphics
import Foundation

/// One numbered exercise printed on a schoolbook page, and where it sits on it.
///
/// The point of knowing where it sits is that it can then be tapped: the
/// student picks the task off the page instead of describing it in the prompt
/// field, which for "Löse Aufgabe 1" is both slower and less exact than
/// pointing at it.
struct BookPageTask: Identifiable, Hashable, Sendable {
    /// The page it is printed on, as a PDF page — the number Buch-KI is told.
    let pdfPage: Int
    /// The number in the little coloured box in front of it.
    let number: Int
    /// Its wording, read off the page.
    let text: String
    /// Where it sits, in that page's own coordinate space (PDFKit's: points,
    /// origin at the bottom left of the crop box).
    let bounds: CGRect

    var id: String { "\(pdfPage)-\(number)" }

    var label: String { "Aufgabe \(number)" }

    /// The question that goes to the server when this task is sent.
    ///
    /// It carries the wording as well as the number, because the number alone
    /// is ambiguous the moment two pages are on screen — both halves of a
    /// spread can have an "Aufgabe 1". The pages travel beside the question in
    /// the request, so nothing here needs to name a page.
    func question(note: String = "") -> String {
        var lines = ["Löse Aufgabe \(number)."]
        let wording = Self.shortened(text)
        if !wording.isEmpty {
            lines.append("Die Aufgabenstellung auf der Seite lautet: „\(wording)“")
        }
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            lines.append(extra)
        }
        return lines.joined(separator: "\n")
    }

    /// One line, and short enough that the server's question limit is never the
    /// thing that fails. The AI reads the real page anyway; this says *which*
    /// task, it does not replace it.
    static func shortened(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > maxWordingCharacters else { return flat }
        return String(flat.prefix(maxWordingCharacters)) + "…"
    }

    static let maxWordingCharacters = 600
}

/// One line of text recognised on a rendered page, with its box in normalised
/// page coordinates (origin bottom left, the way Vision reports them).
///
/// Keeping this separate from Vision itself is what makes the grouping below
/// testable: the awkward part of finding exercises is not reading the letters,
/// it is deciding which lines belong to which task.
struct RecognisedLine: Equatable, Sendable {
    let text: String
    let box: CGRect
}

/// Turns recognised lines into tappable exercises.
///
/// Schoolbooks set exercises as a numbered list: a small boxed number, the
/// wording beside it, continuation lines indented under it. Three things make
/// this harder than matching a leading digit:
///
/// * the number is its own graphic, so recognition often reports it as a line
///   of its own next to the wording rather than as part of it;
/// * literary pages carry a *line-number ruler* down the margin — 5, 10, 15 —
///   which looks exactly like a list of task numbers with text to their right;
/// * a page has two columns, so "the next line down" is regularly in the other
///   one.
///
/// So bare numbers are folded into the line beside them, rulers are told apart
/// by their own arithmetic (they step by five, a task list counts up by one)
/// and dropped, and a task only ever grows by lines sitting under it
/// horizontally — which keeps it inside its column without modelling columns.
enum BookTaskLayout {
    /// Highest exercise number a schoolbook page realistically prints.
    private static let highestNumber = 30
    /// Below this many characters a "task" is a caption, a running head or
    /// noise.
    private static let shortestWording = 12
    /// How far right of a bare number its wording may start, as a fraction of
    /// the page width.
    private static let numberGap: CGFloat = 0.09
    /// A vertical gap wider than this many line heights ends a task.
    private static let breakingGap: CGFloat = 2.2
    private static let maxTasksPerPage = 24

    private struct Start {
        let position: Int
        let number: Int
        let rest: String
    }

    static func tasks(from lines: [RecognisedLine], pdfPage: Int, pageBounds: CGRect) -> [BookPageTask] {
        let candidates = merged(lines)
        var tasks: [BookPageTask] = []
        for start in starts(in: candidates) {
            let block = blockLines(from: start, in: candidates)
            let wording = wordingOf(block, startingWith: start)
            guard wording.count >= shortestWording else { continue }
            let box = block.dropFirst().reduce(block[0].box) { $0.union($1.box) }
            tasks.append(BookPageTask(
                pdfPage: pdfPage,
                number: start.number,
                text: wording,
                bounds: pageRect(box, in: pageBounds)
            ))
            if tasks.count >= maxTasksPerPage { break }
        }
        return tasks
    }

    // MARK: - Reading a number off a line

    /// The exercise number a line starts with, and what is left of the line.
    /// A year ("2010") and a media code ("129040") are not exercise numbers,
    /// which is why more than two digits disqualifies the line.
    static func leadingNumber(_ text: String) -> (number: Int, rest: String)? {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var index = 0
        var digits = ""
        while index < characters.count, characters[index].isNumber {
            digits.append(characters[index])
            index += 1
        }
        guard digits.count <= 2, let number = Int(digits), (1 ... highestNumber).contains(number) else {
            return nil
        }
        if index < characters.count, ".):]".contains(characters[index]) {
            index += 1
        }
        let rest = String(characters[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, rest)
    }

    // MARK: - Folding the boxed numbers back into their wording

    /// Every line, top of the page first, with margin rulers removed and each
    /// bare number joined to the wording beside it.
    static func merged(_ lines: [RecognisedLine]) -> [RecognisedLine] {
        let rulers = rulerIndices(lines)
        let kept = lines.enumerated()
            .filter { !rulers.contains($0.offset) }
            .map(\.element)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.box.maxY > $1.box.maxY }

        // Pair first, rewrite second: a wording line can sit either side of its
        // number in reading order, and rewriting as we go would let the same
        // line be both emitted on its own and folded into a number.
        var partnerOf: [Int: Int] = [:]
        var taken = Set<Int>()
        for (index, line) in kept.enumerated() {
            guard let parsed = leadingNumber(line.text), parsed.rest.isEmpty,
                  let partner = wordingBeside(index, in: kept, taken: taken) else { continue }
            partnerOf[index] = partner
            taken.insert(partner)
        }

        var result: [RecognisedLine] = []
        for (index, line) in kept.enumerated() where !taken.contains(index) {
            guard let partner = partnerOf[index], let parsed = leadingNumber(line.text) else {
                result.append(line)
                continue
            }
            result.append(RecognisedLine(
                text: "\(parsed.number) \(kept[partner].text)",
                box: line.box.union(kept[partner].box)
            ))
        }
        return result.sorted { $0.box.maxY > $1.box.maxY }
    }

    /// The wording that belongs to a number standing on its own: the nearest
    /// line on the same row, starting just to its right.
    private static func wordingBeside(_ number: Int, in lines: [RecognisedLine], taken: Set<Int>) -> Int? {
        let box = lines[number].box
        var best: Int?
        for (index, candidate) in lines.enumerated() where index != number && !taken.contains(index) {
            let overlap = min(candidate.box.maxY, box.maxY) - max(candidate.box.minY, box.minY)
            guard overlap > box.height * 0.4 else { continue }
            let gap = candidate.box.minX - box.maxX
            guard gap >= -0.01, gap < numberGap else { continue }
            if let current = best, lines[current].box.minX <= candidate.box.minX { continue }
            best = index
        }
        return best
    }

    /// Indices of margin line numbers — the "5, 10, 15" ruler beside a literary
    /// text.
    ///
    /// They are bare numbers in a column with wording to their right, which is
    /// structurally the same thing as a list of exercise numbers, and on a page
    /// like P.A.U.L.D. 58 they even share the margin with one. What separates
    /// them is how they count: a ruler steps by five, an exercise list by one.
    /// So the column is cut into runs of constant step and only the runs that
    /// count in anything other than ones are dropped — which leaves the task
    /// numbers standing directly underneath a ruler untouched.
    private static func rulerIndices(_ lines: [RecognisedLine]) -> Set<Int> {
        let bare: [Bare] = lines.enumerated().compactMap { index, line in
            guard let parsed = leadingNumber(line.text), parsed.rest.isEmpty else { return nil }
            return Bare(index: index, number: parsed.number, box: line.box)
        }
        guard bare.count >= 3 else { return [] }

        var drop: Set<Int> = []
        var handled = Set<Int>()
        for anchor in bare where !handled.contains(anchor.index) {
            let column = bare
                .filter { abs($0.box.midX - anchor.box.midX) < 0.03 }
                .sorted { $0.box.maxY > $1.box.maxY }
            handled.formUnion(column.map(\.index))
            guard column.count >= 3 else { continue }
            for run in runs(of: column.map(\.number)) where run.step != 1 && run.length >= 3 {
                drop.formUnion(column[run.start ..< run.start + run.length].map(\.index))
            }
        }
        return drop
    }

    private struct Bare {
        let index: Int
        let number: Int
        let box: CGRect
    }

    private struct Run {
        let start: Int
        let length: Int
        let step: Int
    }

    /// The maximal stretches of a sequence that count by the same amount.
    private static func runs(of values: [Int]) -> [Run] {
        guard values.count >= 2 else { return [] }
        var result: [Run] = []
        var start = 0
        var step = values[1] - values[0]
        for index in 1 ..< values.count {
            let current = values[index] - values[index - 1]
            guard current != step else { continue }
            if index - start >= 2 {
                result.append(Run(start: start, length: index - start, step: step))
            }
            start = index - 1
            step = current
        }
        result.append(Run(start: start, length: values.count - start, step: step))
        return result
    }

    // MARK: - Which lines open a task

    /// The lines that open an exercise, in reading order.
    ///
    /// Only a run that counts up survives: a schoolbook prints 1, 2, 3, so a
    /// number that breaks the count started a sentence rather than a task. One
    /// step may be skipped, because a boxed number is occasionally not read.
    private static func starts(in lines: [RecognisedLine]) -> [Start] {
        var kept: [Start] = []
        for (position, line) in lines.enumerated() {
            guard let parsed = leadingNumber(line.text), parsed.rest.count >= shortestWording else {
                continue
            }
            if let last = kept.last {
                guard parsed.number > last.number, parsed.number <= last.number + 2 else { continue }
            } else {
                // a list starts at 1; allow a page that opens mid-list
                guard parsed.number <= 3 else { continue }
            }
            kept.append(Start(position: position, number: parsed.number, rest: parsed.rest))
        }
        return kept
    }

    // MARK: - How far a task reaches

    /// One task's lines: its opening line plus every line below that sits under
    /// it horizontally, up to the next task or a paragraph-sized gap.
    private static func blockLines(from start: Start, in lines: [RecognisedLine]) -> [RecognisedLine] {
        let first = lines[start.position]
        var block = [first]
        var reach = first.box
        let height = max(first.box.height, 0.001)
        for line in lines.dropFirst(start.position + 1) {
            let overlap = min(line.box.maxX, reach.maxX) - max(line.box.minX, reach.minX)
            guard overlap > min(line.box.width, reach.width) * 0.5 else { continue }
            guard reach.minY - line.box.maxY < height * breakingGap else { break }
            if let next = leadingNumber(line.text), next.rest.count >= shortestWording,
               next.number > start.number {
                break
            }
            block.append(line)
            reach = reach.union(line.box)
        }
        return block
    }

    private static func wordingOf(_ block: [RecognisedLine], startingWith start: Start) -> String {
        let rest = block.dropFirst().map(\.text)
        return ([start.rest] + rest).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalised box -> the page's own points, padded a little so the tap
    /// target does not sit exactly on the letters.
    private static func pageRect(_ box: CGRect, in bounds: CGRect) -> CGRect {
        let rect = CGRect(
            x: bounds.minX + box.minX * bounds.width,
            y: bounds.minY + box.minY * bounds.height,
            width: box.width * bounds.width,
            height: box.height * bounds.height
        )
        return rect.insetBy(dx: -bounds.width * 0.012, dy: -bounds.height * 0.006)
    }
}
