import Foundation

extension BackendAPI.LessonInfo {
    /// The content-specific name of a recorded lesson. A generated topic wins
    /// over timetable metadata because it is what distinguishes two recordings
    /// of the same subject.
    var displayTitle: String {
        if let topic = nonEmpty(topic) { return topic }
        if let derived = lessonTopic(from: summaryExcerpt)?.headline { return derived }
        if let title = nonEmpty(title) { return title }
        if let subject = nonEmpty(subject) { return subject }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// The timetable subject remains visible as context beneath or beside the
    /// generated title.
    var displaySubject: String? {
        nonEmpty(subject) ?? nonEmpty(title)
    }

    /// Menus have room for one line, so they keep the title first and mark the
    /// subject after it.
    var compactDisplayTitle: String {
        guard let displaySubject, displaySubject != displayTitle else { return displayTitle }
        return "\(displayTitle) · \(displaySubject)"
    }

    var usesDateDisplayTitle: Bool {
        nonEmpty(topic) == nil
            && lessonTopic(from: summaryExcerpt) == nil
            && nonEmpty(title) == nil
            && nonEmpty(subject) == nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A lesson's summary, read as a heading and the line under it.
struct LessonTopic {
    /// The opening sentence, without its full stop.
    let headline: String
    /// What followed it inside the excerpt, if the excerpt reached that far.
    let detail: String?
}

private let headlineMinimum = 24
private let sentenceSearchLimit = 96
private let headlineLimit = 52

private let abbreviationsEndingInAStop: Set<String> = [
    "a", "b", "d", "h", "o", "s", "u", "z",
    "abb", "bspw", "bsp", "bzgl", "bzw", "ca", "dh", "dr", "evtl", "etc", "ggf",
    "ggfs", "inkl", "jh", "max", "mind", "nr", "prof", "sog", "usw", "vgl", "vs",
    "zb", "zzgl",
]

/// Split an old summary excerpt into a usable title and the line below it.
func lessonTopic(from excerpt: String?) -> LessonTopic? {
    let flat = (excerpt ?? "")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    guard !flat.isEmpty else { return nil }

    let characters = Array(flat)
    var wordStart = 0
    for (index, character) in characters.enumerated() {
        if character == " " {
            wordStart = index + 1
            continue
        }
        guard character == "." || character == "!" || character == "?" || character == ":" else { continue }
        guard index + 1 < characters.count, characters[index + 1] == " " else { continue }
        guard index >= headlineMinimum else { continue }
        guard index <= sentenceSearchLimit else { break }
        if character == ".", endsAnAbbreviation(String(characters[wordStart ..< index])) { continue }
        let rest = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
        return LessonTopic(
            headline: shortened(String(characters[0 ..< index]), to: headlineLimit),
            detail: rest.isEmpty ? nil : rest
        )
    }
    return LessonTopic(headline: withoutTrailingStop(shortened(flat, to: headlineLimit)), detail: nil)
}

private func withoutTrailingStop(_ text: String) -> String {
    text.hasSuffix(".") || text.hasSuffix(":") ? String(text.dropLast()) : text
}

private func endsAnAbbreviation(_ word: String) -> Bool {
    let letters = word.trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted)
    if letters.isEmpty { return true }
    if letters.allSatisfy(\.isNumber) { return true }
    return abbreviationsEndingInAStop.contains(letters.lowercased())
}

private func shortened(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    let head = String(text.prefix(limit))
    let trailing = CharacterSet(charactersIn: " ,;:.-\u{2013}")
    if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
        return String(head[head.startIndex ..< space]).trimmingCharacters(in: trailing) + "…"
    }
    return head.trimmingCharacters(in: trailing) + "…"
}
