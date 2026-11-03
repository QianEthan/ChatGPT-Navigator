import Foundation

/// Extracts assistant prose from loaded Accessibility nodes. No input or clipboard.
enum ModernResponseText {
    static func extract(in nodes: [ModernConversationNode], following prompt: ModernUserPrompt) -> String? {
        guard let range = ModernResponseCapturePolicy.responseRange(in: nodes, following: prompt.headingIndex) else { return nil }
        let depth = nodes[range.lowerBound].depth
        // The response footer is an observed completion boundary; do not include it.
        guard let end = range.first(where: {
            nodes[$0].depth <= depth && nodes[$0].role == "AXButton" &&
            ["copy", "copy response"].contains(nodes[$0].text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        }) else { return nil }
        let ignored: Set<String> = ["AXButton", "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuItem", "AXTextField", "AXTextArea", "AXComboBox", "AXCheckBox", "AXRadioButton", "AXSlider", "AXToolbar", "AXTime", "AXProgressIndicator", "AXBusyIndicator", "AXSplitter"]
        func render(_ index: Int, listItem: Bool = false) -> (String, Int) {
            let node = nodes[index]
            var next = index + 1
            while next < end && nodes[next].depth > node.depth { next += 1 }
            if ignored.contains(node.role) || node.subrole == "AXApplicationStatus" { return ("", next) }
            if ["AXStaticText", "AXHeading", "AXLink", "AXListMarker"].contains(node.role) {
                if ModernConversationParser.speaker(node.text) != nil && node.depth <= depth + 1 { return ("", next) }
                if node.depth <= depth { return ("", next) } // sibling timestamps and turn metadata
                if node.role == "AXHeading" { return ("\n\n" + node.text + "\n\n", next) }
                return (node.text + (node.role == "AXListMarker" ? " " : ""), next)
            }
            var pieces = ""
            var child = index + 1
            while child < next {
                let (text, after) = render(child, listItem: node.role == "AXList")
                pieces += text
                child = after
            }
            if node.role == "AXList" || node.depth == depth { pieces += "\n\n" }
            else if listItem { pieces += "\n" }
            return (pieces, next)
        }
        var text = ""
        var index = range.lowerBound + 1
        while index < end {
            let (piece, next) = render(index)
            text += piece
            index = next
        }
        text = text.replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
