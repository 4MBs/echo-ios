import Foundation

/// The two halves of an Antigravity model identifier.
///
/// Antigravity has no separate reasoning setting: the effort is the last
/// segment of the model's own name, so `gemini-3.6-flash-low` and
/// `gemini-3.6-flash-high` are two entries in its list rather than one model
/// with a switch. The server sends the list folded into families — a model,
/// and the efforts it was listed at — and stores the identifier itself, so the
/// two pickers have to be taken apart and put back together somewhere. Here,
/// against `answer/agy_models.py`, which splits and joins by exactly this rule.
enum GeminiModelIdentifier {
    /// Lightest first, the order the picker offers them in.
    static let efforts = ["low", "medium", "high"]

    static func split(_ identifier: String) -> (family: String, effort: String) {
        guard let separator = identifier.lastIndex(of: "-") else { return (identifier, "") }
        let suffix = String(identifier[identifier.index(after: separator)...])
        let family = String(identifier[..<separator])
        guard !family.isEmpty, efforts.contains(suffix) else { return (identifier, "") }
        return (family, suffix)
    }

    static func join(family: String, effort: String) -> String {
        effort.isEmpty ? family : "\(family)-\(effort)"
    }

    /// What the picker calls an effort. Antigravity offers three, and they are
    /// the same three ideas ChatGPT's intelligence levels name.
    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "low": "Leicht"
        case "medium": "Mittel"
        case "high": "Hoch"
        default: effort
        }
    }
}
