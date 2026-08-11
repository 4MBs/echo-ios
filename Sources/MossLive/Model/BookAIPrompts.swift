import Foundation

/// Feature-specific instructions for questions about a book page.
///
/// The server owns the model's system prompt. These instructions therefore
/// travel with the student's request and focus only on what the client knows:
/// the selected task, the visible page or region, and the presentation that is
/// useful in a reading interface.
enum BookAIPrompts {
    static let explainPage = """
    Erkläre den Inhalt dieser Seite verständlich. Stelle zuerst die Kernaussage heraus, erkläre danach die Zusammenhänge und definiere Fachbegriffe knapp.
    """

    static let summarizePage = """
    Fasse diese Seite knapp zusammen. Nenne nur die wichtigsten Aussagen und hebe Begriffe oder Ergebnisse hervor, die man sich merken sollte.
    """

    static let explainFigure = """
    Untersuche die wichtigste Abbildung, Karte, Tabelle oder das wichtigste Diagramm auf dieser Seite. Erkläre zuerst, was dargestellt wird, dann wie man es liest und zuletzt, welche Aussage daraus folgt. Falls keine Abbildung erkennbar ist, sage das klar.
    """

    static func solveExercise(_ number: String) -> String {
        """
        Löse Aufgabe \(number). Gib zuerst das Ergebnis an und zeige danach den vollständigen Lösungsweg in nachvollziehbaren, nummerierten Schritten. Begründe jeden nicht offensichtlichen Schritt und prüfe das Ergebnis, wenn das möglich ist. Falls die Aufgabe oder notwendige Angaben auf den ausgewählten Seiten nicht eindeutig erkennbar sind, benenne genau, was fehlt, statt etwas zu erfinden.
        """
    }

    static let simplerFollowUp = "Erkläre die vorige Antwort noch einmal einfacher, ohne wichtige Bedingungen wegzulassen."
    static let exampleFollowUp = "Gib ein konkretes, kurzes Beispiel, das die vorige Erklärung veranschaulicht."
    static let stepsFollowUp = "Erkläre die vorige Antwort als nachvollziehbare, nummerierte Schrittfolge."
    static let whyFollowUp = "Begründe die vorige Antwort und erkläre die entscheidende Ursache oder Regel."
    static let shorterFollowUp = "Fasse die vorige Antwort kürzer und einfacher zusammen. Behalte das Ergebnis und alle notwendigen Einschränkungen bei."

    /// A stable response contract makes answers scan well without forcing each
    /// starter action to repeat the same formatting rules.
    static func formatted(_ request: String) -> String {
        """
        \(request.trimmingCharacters(in: .whitespacesAndNewlines))

        Anforderungen an die Antwort:
        - Antworte in der Sprache der Frage, standardmäßig auf Deutsch.
        - Stütze dich auf die ausgewählten Buchseiten. Trenne klar zwischen dem, was dort erkennbar ist, und ergänzendem Allgemeinwissen.
        - Erfinde keine Aufgabenstellung, Werte, Beschriftungen, Zitate oder Seiteninhalte. Sage präzise, wenn etwas fehlt oder nicht lesbar ist.
        - Beginne direkt mit der Antwort. Verwende kurze, aussagekräftige Markdown-Überschriften mit `##`.
        - Hebe das Endergebnis und zentrale Begriffe **fett** hervor. Verwende nummerierte Listen für Lösungswege und Aufzählungen nur für echte Listen.
        - Setze alleinstehende Formeln in einen Markdown-Codeblock mit der Sprache `math` und erkläre anschließend alle Variablen. Verwende keine Tabellen und keine unnötige Einleitung.
        - Formuliere knapp, aber vollständig und so, dass die Antwort ohne weitere Umformatierung gut lesbar ist.
        """
    }
}
