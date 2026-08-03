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
/// wording beside it, continuation lines indented under it. Four things make
/// this harder than matching a leading digit, and every rule below is one of
/// them:
///
/// * **The number is its own graphic**, so recognition often reports it as a
///   line of its own beside the wording. Bare numbers are folded back into the
///   line to their right.
/// * **Literary pages carry a line-number ruler** down the margin — 5, 10, 15
///   — which is structurally identical to a list of task numbers, and which
///   recognition sometimes glues onto the body line ("25 konnte wirklich
///   nicht sagen, dass…"). So rulers are spotted among *all* lines beginning
///   with a number, not just bare ones, and told apart by their arithmetic:
///   they step by five, an exercise list counts up by one.
/// * **The running head is numbered too.** "1 Familienbeziehungen" at the top
///   of a page parses exactly like an exercise, and it used to become one —
///   and, being a 1, to take the place of the page's real Aufgabe 1. The top
///   and bottom margins are not read.
/// * **Exercise numbering does not restart per page.** A spread's list runs
///   8, 9 on the left page and 1 … 8 on the right; a column may open at 5.
///   So a run is accepted wherever it starts, as long as it counts up by one
///   within one column — a lone number is only believed when it is low.
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
    private static let breakingGap: CGFloat = 2.0
    /// Two numbers belong to the same column when their lines start within
    /// this fraction of the page width of each other.
    private static let columnTolerance: CGFloat = 0.06
    /// Margins that carry the running head and the page number, as fractions
    /// of the page height. Nothing in them is ever an exercise.
    private static let headerBand: CGFloat = 0.06
    private static let footerBand: CGFloat = 0.04
    /// How many numbers in a row it takes to call something a ruler.
    private static let rulerRun = 3
    /// A number standing on its own is only an exercise if it is low enough to
    /// open a list — otherwise it is a stray line number or a date.
    private static let loneNumberLimit = 3
    /// No exercise fills a fifth of the page; a block that would has run into
    /// whatever is printed under it.
    private static let maxBlockHeight: CGFloat = 0.22
    private static let maxTasksPerPage = 24

    private struct Start {
        let position: Int
        let number: Int
        let rest: String
        let box: CGRect
    }

    static func tasks(from lines: [RecognisedLine], pdfPage: Int, pageBounds: CGRect) -> [BookPageTask] {
        let body = lines.filter(isInsideBody)
        let candidates = merged(withoutRulers(body))
        var tasks: [BookPageTask] = []
        for start in accepted(in: candidates) {
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

    /// Whether a line is in the part of the page that carries content, rather
    /// than in the running head or the footer.
    private static func isInsideBody(_ line: RecognisedLine) -> Bool {
        line.box.midY < 1 - headerBand && line.box.midY > footerBand
    }

    // MARK: - Reading a number off a line

    /// Any number a line starts with, and what is left of the line. A year
    /// ("2010") and a media code ("129040") are not what this is looking for,
    /// which is why more than three digits disqualifies the line.
    ///
    /// Line numbers run past any exercise number — a page of prose is ruled up
    /// to 110 — so spotting a *ruler* has to see those, which is why this is
    /// not capped at an exercise number the way `leadingNumber` is.
    static func leadingInteger(_ text: String) -> (number: Int, rest: String)? {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var index = 0
        var digits = ""
        while index < characters.count, characters[index].isNumber {
            digits.append(characters[index])
            index += 1
        }
        guard digits.count <= 3, let number = Int(digits), number >= 1 else { return nil }
        if index < characters.count, ".):]".contains(characters[index]) {
            index += 1
        }
        let rest = String(characters[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, rest)
    }

    /// The same, narrowed to numbers a schoolbook actually prints on an
    /// exercise.
    static func leadingNumber(_ text: String) -> (number: Int, rest: String)? {
        guard let parsed = leadingInteger(text), parsed.number <= highestNumber else { return nil }
        return parsed
    }

    // MARK: - Folding the boxed numbers back into their wording

    /// Every line, top of the page first, with each bare number joined to the
    /// wording beside it.
    static func merged(_ lines: [RecognisedLine]) -> [RecognisedLine] {
        let kept = lines
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

    /// The lines with the margin line-number ruler taken out — the "5, 10, 15"
    /// down the side of a literary text.
    ///
    /// This is the rule that stops a page of prose being covered in boxes. A
    /// ruler is structurally identical to a list of exercise numbers, and
    /// recognition reports it two different ways on the same book: sometimes
    /// as a bare number of its own, sometimes glued to the body line it sits
    /// beside ("25 konnte wirklich nicht sagen, dass…"). Both look like
    /// exercises, so both are considered here, and what separates them is how
    /// they count: a ruler steps by five, an exercise list counts up by one.
    /// The column is cut into runs of constant step and only runs that count
    /// in something other than ones are dropped, which leaves exercise numbers
    /// standing in the same margin untouched.
    static func withoutRulers(_ lines: [RecognisedLine]) -> [RecognisedLine] {
        let numbered: [Numbered] = lines.enumerated().compactMap { index, line in
            guard let parsed = leadingInteger(line.text) else { return nil }
            return Numbered(index: index, number: parsed.number, box: line.box)
        }
        guard numbered.count >= rulerRun else { return lines }

        var drop: Set<Int> = []
        var handled = Set<Int>()
        for anchor in numbered where !handled.contains(anchor.index) {
            let column = numbered
                .filter { abs($0.box.minX - anchor.box.minX) < columnTolerance }
                .sorted { $0.box.maxY > $1.box.maxY }
            handled.formUnion(column.map(\.index))
            guard column.count >= rulerRun else { continue }
            for run in runs(of: column.map(\.number)) where abs(run.step) != 1 && run.length >= rulerRun {
                drop.formUnion(column[run.start ..< run.start + run.length].map(\.index))
            }
        }
        return lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    private struct Numbered {
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
    /// A number is believed when the column it stands in counts up by one
    /// through it — which is what an exercise list does and what a stray
    /// number in prose does not. Where the count *starts* says nothing: a
    /// spread's list runs 8, 9 at the foot of the left page and 1 … 8 down the
    /// right one, and a second column regularly opens at 5 or 8. Requiring it
    /// to start low was what left most of a book undetected.
    ///
    /// A number with no neighbours is only believed when it is low enough to
    /// open a list, since a page really can carry a single "1".
    private static func accepted(in lines: [RecognisedLine]) -> [Start] {
        var candidates: [Start] = []
        for (position, line) in lines.enumerated() {
            guard let parsed = leadingNumber(line.text), parsed.rest.count >= shortestWording else {
                continue
            }
            candidates.append(Start(
                position: position,
                number: parsed.number,
                rest: parsed.rest,
                box: line.box
            ))
        }

        var keep = Set<Int>()
        var handled = Set<Int>()
        for anchor in candidates where !handled.contains(anchor.position) {
            let column = candidates
                .filter { abs($0.box.minX - anchor.box.minX) < columnTolerance }
                .sorted { $0.box.maxY > $1.box.maxY }
            handled.formUnion(column.map(\.position))
            for run in runs(of: column.map(\.number)) where run.step == 1 && run.length >= 2 {
                keep.formUnion(column[run.start ..< run.start + run.length].map(\.position))
            }
            for start in column where !keep.contains(start.position) && start.number <= loneNumberLimit {
                keep.insert(start.position)
            }
        }
        return candidates.filter { keep.contains($0.position) }
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
            // whatever sits below is long past the end of an exercise
            guard reach.union(line.box).height < maxBlockHeight else { break }
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
