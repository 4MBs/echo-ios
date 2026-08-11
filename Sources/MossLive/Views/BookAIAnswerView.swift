import SwiftUI
import UIKit

/// A small block parser for the predictable Markdown requested from Book AI.
/// Keeping the model's original text intact preserves copying and sharing,
/// while rendering blocks separately gives headings, steps and formulas a
/// useful visual hierarchy.
struct BookAIAnswerDocument: Equatable {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case ordered(number: Int, text: String)
        case unordered(String)
        case quote(String)
        case formula(String)
        case code(String)
    }

    let blocks: [Block]

    init(markdown: String) {
        var result: [Block] = []
        var paragraph: [String] = []
        var fenced: [String] = []
        var fenceLanguage: String?

        func flushParagraph() {
            let text = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.paragraph(text)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushFence() {
            let text = fenced.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(fenceLanguage == "math" ? .formula(text) : .code(text))
            }
            fenced.removeAll(keepingCapacity: true)
            fenceLanguage = nil
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if fenceLanguage == nil {
                    flushParagraph()
                    fenceLanguage = String(line.dropFirst(3)).lowercased()
                } else {
                    flushFence()
                }
                continue
            }
            if fenceLanguage != nil {
                fenced.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count > 4 {
                flushParagraph()
                result.append(.formula(String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("\\["), line.hasSuffix("\\]"), line.count > 4 {
                flushParagraph()
                result.append(.formula(String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let heading = Self.heading(in: line) {
                flushParagraph()
                result.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if let item = Self.orderedItem(in: line) {
                flushParagraph()
                result.append(.ordered(number: item.number, text: item.text))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                result.append(.unordered(String(line.dropFirst(2))))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(String(line.dropFirst(2))))
                continue
            }
            if Self.isSectionLabel(line) {
                flushParagraph()
                result.append(.heading(level: 2, text: String(line.dropLast())))
                continue
            }
            paragraph.append(line)
        }
        if fenceLanguage != nil { flushFence() }
        flushParagraph()
        blocks = result.isEmpty ? [.paragraph(markdown)] : result
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6 else { return nil }
        let remainder = line.dropFirst(hashes)
        guard remainder.first == " " else { return nil }
        return (min(hashes, 3), remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func orderedItem(in line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let prefix = line[..<dot]
        guard let number = Int(prefix), number > 0 else { return nil }
        let remainder = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        return (number, remainder)
    }

    private static func isSectionLabel(_ line: String) -> Bool {
        guard line.hasSuffix(":"), line.count < 60 else { return false }
        let label = line.dropLast().lowercased()
        return [
            "antwort",
            "ergebnis",
            "lösung",
            "lösungsweg",
            "schritte",
            "erklärung",
            "begründung",
            "wichtig",
            "merksatz",
            "prüfung"
        ].contains(label)
    }
}

struct BookAIAnswerView: View {
    let text: String

    private var document: BookAIAnswerDocument { BookAIAnswerDocument(markdown: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func blockView(_ block: BookAIAnswerDocument.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inlineMarkdown(text))
                .font(level == 1 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        case let .paragraph(text):
            Text(inlineMarkdown(text))
                .font(.body)
                .lineSpacing(3)
        case let .ordered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number).")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                Text(inlineMarkdown(text))
                    .font(.body)
                    .lineSpacing(3)
            }
        case let .unordered(text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(inlineMarkdown(text))
                    .font(.body)
                    .lineSpacing(3)
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        case let .formula(text):
            formula(text)
        case let .code(text):
            code(text)
        }
    }

    private func formula(_ formula: String) -> some View {
        ScrollView(.horizontal) {
            Text(formula)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button("Formel kopieren", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = formula
            }
        }
        .accessibilityLabel("Formel: \(formula)")
    }

    private func code(_ code: String) -> some View {
        ScrollView(.horizontal) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(12)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func inlineMarkdown(_ value: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
    }
}
