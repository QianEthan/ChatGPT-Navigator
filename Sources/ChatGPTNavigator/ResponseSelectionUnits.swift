import Foundation

/// A formula is one selection unit, rather than a sequence of unrelated glyphs.
enum ResponseSelectionUnits {
    struct Unit: Equatable {
        let range: Range<Int>
        let isMath: Bool
    }
    static func collect(in nodes: [ModernConversationNode], body: Range<Int>, headingDepth: Int) -> [Unit] {
        let controls: Set<String> = ["AXButton", "AXPopUpButton", "AXCheckBox", "AXTextArea", "AXTextField", "AXTime", "AXProgressIndicator", "AXBusyIndicator"]
        var result: [Unit] = []
        var index = body.lowerBound
        while index < body.upperBound {
            let node = nodes[index]
            var end = index + 1
            while end < body.upperBound && nodes[end].depth > node.depth { end += 1 }
            if controls.contains(node.role) || node.subrole == "AXApplicationStatus" {
                index = end; continue
            }
            if node.subrole == "AXDocumentMath" || node.subrole.hasPrefix("AXMath") || node.role == "AXMath" {
                result.append(Unit(range: index..<end, isMath: true))
                index = end; continue
            }
            if ["AXStaticText", "AXHeading", "AXLink"].contains(node.role), node.depth > headingDepth,
               !node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !(node.depth <= headingDepth + 1 && ModernConversationParser.speaker(node.text) != nil) {
                    result.append(Unit(range: index..<end, isMath: false))
                }
                index = end; continue
            }
            index += 1
        }
        return result
    }
    static func mathPoint(bounds: CGRect, end: Bool, viewport: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height >= 4, !bounds.isNull, !bounds.isInfinite,
              viewport.insetBy(dx: -0.5, dy: -0.5).contains(bounds) else { return nil }
        let inset = min(4, bounds.height / 4)
        let point = CGPoint(x: end ? bounds.maxX + 2 : bounds.minX - 2,
                            y: end ? bounds.maxY - inset : bounds.minY + inset)
        return viewport.contains(point) ? point : nil
    }
}
