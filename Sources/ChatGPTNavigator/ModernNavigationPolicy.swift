import Foundation

/// Value-only decisions, shared with tests. Find chooses an occurrence;
/// navigation checks text without requiring a stable message identity.
enum ModernNavigationPolicy {
    static func isVisible(frame: CGRect, viewport: CGRect) -> Bool {
        let intersection = frame.intersection(viewport.insetBy(dx: 0, dy: 2))
        return !intersection.isNull && intersection.width > 0 && intersection.height >= 8
    }

    static func canonical(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func query(for text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).map(canonical).filter { !$0.isEmpty }
        guard let longest = lines.max(by: { $0.count < $1.count }) else { return nil }
        // A single line works with the app's Find UI and avoids pasting Return.
        return String(longest.prefix(100))
    }

    static func isFindField(role: String, subrole: String, labels: [String]) -> Bool {
        guard ["AXTextField", "AXSearchField", "AXComboBox"].contains(role) else { return false }
        let values = labels.map { canonical($0).lowercased() }
        // Generic "Search" also labels global search. Require an explicit
        // Find marker or a conversation-specific search label.
        return values.contains { value in
            value.range(of: #"(?:^|[^a-z])find(?:$|[^a-z]|input|field)"#,
                        options: .regularExpression) != nil ||
                ["search in conversation", "search this conversation", "search conversation",
                 "search in chat", "search this chat"].contains(value)
        }
    }

    static func matchingIndices(text: String, entries: [ModernPromptObservation]) -> [Int] {
        let key = canonical(text)
        guard !key.isEmpty else { return [] }
        return entries.indices.filter { canonical(entries[$0].text) == key }
    }
}
