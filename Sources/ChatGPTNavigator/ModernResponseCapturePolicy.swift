import Foundation

/// Keep capture scoped to the assistant turn immediately following a known prompt.
enum ModernResponseCapturePolicy {
    static func clickPoint(button: CGRect, window: CGRect) -> CGPoint? {
        guard !button.isNull, !button.isInfinite, !window.isNull,
              button.width >= 4, button.height >= 4,
              button.width <= 200, button.height <= 120,
              window.contains(button) else { return nil }
        return CGPoint(x: button.midX, y: button.midY)
    }

    static func nodeText(role: String, read: () -> String) -> String {
        ["AXHeading", "AXStaticText", "AXTime", "AXButton", "AXListMarker", "AXLink"].contains(role) ? read() : ""
    }

    static func responseRange(in nodes: [ModernConversationNode], following heading: Int) -> Range<Int>? {
        guard nodes.indices.contains(heading) else { return nil }
        let depth = nodes[heading].depth
        let headings = nodes.indices.filter {
            $0 > heading && nodes[$0].role == "AXHeading" && nodes[$0].depth == depth &&
                ModernConversationParser.speaker(nodes[$0].text) != nil
        }
        guard let first = headings.first,
              ModernConversationParser.speaker(nodes[first].text) == .assistant else { return nil }
        return first..<(headings.dropFirst().first ?? nodes.count)
    }

    static func footerButtons(in nodes: [ModernConversationNode], range: Range<Int>) -> [Int] {
        guard let heading = range.first else { return [] }
        let depth = nodes[heading].depth
        return range.filter {
            nodes[$0].depth <= depth && nodes[$0].role == "AXButton" &&
                ["copy", "copy response"].contains(nodes[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    static func copyButtons(in nodes: [ModernConversationNode], range: Range<Int>) -> [Int] {
        range.filter {
            nodes[$0].role == "AXButton" &&
                ["copy", "copy response", "copy message"].contains(
                    nodes[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }
    static func copyAction(_ action: String) -> Bool {
        guard let line = action.split(separator: "\n").first, line.hasPrefix("Name:") else { return false }
        return ["copy", "copy response", "copy message"].contains(
            line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
