import Foundation

/// A value-only representation of a preorder Accessibility walk. Tests use
/// synthetic trees; parsing never needs to connect to or control another app.
struct ModernConversationNode {
    let role: String
    let text: String
    let depth: Int
    var subrole: String = ""
}

struct ModernUserPrompt: Equatable {
    let text: String
    let sourceIndices: [Int]
    let turn: Int
    let headingIndex: Int
    let bodyRange: Range<Int>
}

enum ModernConversationParser {
    enum Speaker { case user, assistant }

    static func speaker(_ text: String) -> Speaker? {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        switch label {
        case "you said": return .user
        case "chatgpt said", "codex said", "assistant said": return .assistant
        default: return nil
        }
    }

    /// English speaker headings are the observed message boundaries. Only the
    /// shallowest matching heading level is structural: a quoted "You said:"
    /// inside an assistant's Markdown must not manufacture another user turn.
    static func userPrompts(
        in nodes: [ModernConversationNode],
        includeTrailingMessage: Bool = true
    ) -> [ModernUserPrompt] {
        let headerDepth = nodes.filter { $0.role == "AXHeading" && speaker($0.text) != nil }
            .map(\.depth).min()
        guard let headerDepth else { return [] }

        let controls: Set<String> = [
            "AXButton", "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuItem",
            "AXTextField", "AXTextArea", "AXComboBox", "AXCheckBox", "AXRadioButton",
            "AXSlider", "AXToolbar", "AXTabGroup",
        ]
        var result: [ModernUserPrompt] = []
        var current: Speaker?
        var turn = -1
        var headingIndex = 0
        var indices: [Int] = []
        var fragments: [String] = []
        var ignoredSubtreeDepth: Int?
        var ancestors: [Int] = []
        var bodyRoot: Int?
        var bodyDepth: Int?

        func flush(endingAt end: Int) {
            if current == .user, !fragments.isEmpty {
                result.append(ModernUserPrompt(
                    text: fragments.joined(separator: "\n"),
                    sourceIndices: indices, turn: turn, headingIndex: headingIndex,
                    bodyRange: (bodyRoot ?? indices[0])..<end
                ))
            }
            fragments = []
            indices = []
            bodyRoot = nil
            bodyDepth = nil
        }

        for (index, node) in nodes.enumerated() {
            while let last = ancestors.last, nodes[last].depth >= node.depth { ancestors.removeLast() }
            // Speaker headings can be delayed or absent during a streaming
            // response. Once the prompt's sibling body subtree ends, stop
            // collecting user text regardless of what follows it.
            if current == .user, let root = bodyRoot, let depth = bodyDepth,
               index > root, node.depth <= depth {
                flush(endingAt: index)
                current = nil
            }
            let path = ancestors
            ancestors.append(index)
            if let depth = ignoredSubtreeDepth {
                if node.depth > depth { continue }
                ignoredSubtreeDepth = nil
            }
            if controls.contains(node.role) || node.role == "AXTime" {
                ignoredSubtreeDepth = node.depth
                continue
            }
            if node.role == "AXHeading", node.depth == headerDepth,
               let role = speaker(node.text) {
                flush(endingAt: index)
                current = role
                turn += 1
                headingIndex = index
                continue
            }
            // A turn has ended if the walk leaves its common sibling level.
            if node.depth < headerDepth { flush(endingAt: index); current = nil }
            guard current == .user,
                  node.role == "AXStaticText" || node.role == "AXHeading" else { continue }
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Chromium may expose the heading's accessible name again as a
            // direct text child. Only that shallow label is metadata.
            if node.depth == headerDepth + 1 && speaker(text) == current { continue }
            // The supplied tree places metadata times beside the speaker
            // heading. A time typed inside the message remains content.
            if node.depth <= headerDepth + 1 && isTimestamp(text) { continue }
            if bodyRoot == nil {
                // The supplied Chromium tree puts the user bubble in a group
                // following "You said:". Scope to the outermost body group
                // beneath that heading's sibling level, not the entire turn.
                if let root = path.first(where: {
                    $0 > headingIndex && nodes[$0].depth >= headerDepth &&
                        ["AXGroup", "AXParagraph", "AXList", "AXOutline"].contains(nodes[$0].role)
                }) {
                    bodyRoot = root
                    bodyDepth = nodes[root].depth
                } else {
                    bodyRoot = index
                    bodyDepth = node.depth
                }
            }
            fragments.append(text)
            indices.append(index)
            // Avoid counting text again if Chromium also exposes its leaf.
            ignoredSubtreeDepth = node.depth
        }
        if includeTrailingMessage { flush(endingAt: nodes.count) }
        return result
    }

    private static func isTimestamp(_ text: String) -> Bool {
        text.range(of: #"^(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*[APap][Mm])?$"#,
                   options: .regularExpression) != nil
    }
}
