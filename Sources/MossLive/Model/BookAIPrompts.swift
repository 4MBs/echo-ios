import Foundation

/// Shared answer requirements for free-form questions about a book page.
enum BookAIPrompts {
    /// A stable response contract keeps free-form answers grounded and
    /// readable without imposing a task-specific workflow on the conversation.
    static func formatted(_ request: String) -> String {
        """
        \(request.trimmingCharacters(in: .whitespacesAndNewlines))

        Anforderungen an die Antwort:
        - Antworte in der Sprache der Frage, standardmäßig auf Deutsch.
        - Stütze dich auf die ausgewählten Buchseiten. Trenne klar zwischen dem, was dort erkennbar ist,
          und ergänzendem Allgemeinwissen.
        - Erfinde keine Aufgabenstellung, Werte, Beschriftungen, Zitate oder Seiteninhalte.
          Sage präzise, wenn etwas fehlt oder nicht lesbar ist.
        - Beginne direkt mit der Antwort. Gliedere sie in kurze Absätze.
        - Hebe zentrale Begriffe **fett** hervor und verwende Listen nur, wenn sie das Lesen erleichtern.
        - Erkläre Variablen in Formeln. Verwende keine Tabellen und keine unnötige Einleitung.
        - Formuliere knapp, aber vollständig und so, dass die Antwort ohne weitere Umformatierung gut lesbar ist.
        """
    }
}
