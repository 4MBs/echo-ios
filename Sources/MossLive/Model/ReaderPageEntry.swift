import Foundation

enum ReaderPageEntry {
    static func sanitized(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(5))
    }

    static func destination(
        for text: String,
        numbering: BookPageNumbering
    ) -> Int? {
        guard text == sanitized(text), let printed = Int(text) else { return nil }
        return numbering.pdfPage(forPrinted: printed)
    }

    static func restoredValue(
        forPDFPage pdfPage: Int,
        numbering: BookPageNumbering
    ) -> String {
        numbering.printedLabel(pdfPage)
    }
}
