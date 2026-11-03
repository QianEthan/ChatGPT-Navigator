import CoreGraphics

/// Snapshot-local entry indices. They are mapped to remembered identities only
/// after the same snapshot has been reconciled by ModernPromptMemory.
struct ModernLocationEvidence: Sendable {
    enum Anchor: Equatable, Sendable {
        case prompt(Int), between(Int, Int), before(Int), after(Int)
    }
    let anchor: Anchor?
    let viewport: CGRect
    let allowsFrameEstimate: Bool
}

enum ModernConversationLocation {
    /// A hit inside a prompt's parsed body is direct evidence. Hits elsewhere
    /// in the Conversation landmark bracket the viewport by nearby user turns.
    static func anchor(at index: Int, nodes: [ModernConversationNode],
                       prompts: [ModernUserPrompt]) -> ModernLocationEvidence.Anchor? {
        guard nodes.indices.contains(index), !prompts.isEmpty else { return nil }
        if let prompt = prompts.firstIndex(where: { $0.bodyRange.contains(index) }) {
            return .prompt(prompt)
        }
        let node = nodes[index]
        guard ["AXStaticText", "AXHeading", "AXGroup", "AXParagraph", "AXList", "AXCode"].contains(node.role) else { return nil }
        // Whitespace may hit a container spanning many messages. Its position in
        // preorder says nothing about which of its children is actually visible.
        let end = nodes.indices.dropFirst(index + 1).first { nodes[$0].depth <= node.depth } ?? nodes.count
        if prompts.contains(where: { (index..<end).contains($0.headingIndex) }) { return nil }
        let before = prompts.indices.last { prompts[$0].bodyRange.upperBound <= index }
        let after = prompts.indices.first { prompts[$0].headingIndex > index }
        switch (before, after) {
        case let (left?, right?): return .between(left, right)
        case let (left?, nil): return .after(left)
        case let (nil, right?): return .before(right)
        default: return nil
        }
    }

    static func locate(evidence: ModernLocationEvidence?, observedIDs: [String],
                       confidentIDs: Set<String>, orderedIDs: [String], groups: [[String]],
                       frames: [(id: String, frame: CGRect?)]) -> ConversationLocation {
        guard let evidence, valid(evidence.viewport) else { return .init() }
        let known = Set(orderedIDs)
        func id(_ index: Int) -> String? {
            guard observedIDs.indices.contains(index) else { return nil }
            let value = observedIDs[index]
            return confidentIDs.contains(value) && known.contains(value) ? value : nil
        }
        func sameGroup(_ first: String, _ second: String) -> Bool {
            groups.contains { $0.contains(first) && $0.contains(second) }
        }
        func gap(_ first: String, _ second: String) -> ConversationLocation {
            guard sameGroup(first, second),
                  let left = orderedIDs.firstIndex(of: first),
                  let right = orderedIDs.firstIndex(of: second), left < right else {
                return .init(section: .near(first), isApproximate: true)
            }
            // Remembered adjacency is not proof that no unencountered turn
            // exists between these prompts in a virtualized conversation.
            return .init(section: .between(first, second), isApproximate: true)
        }
        if let anchor = evidence.anchor {
            switch anchor {
            case .prompt(let index):
                guard let current = id(index) else { return .init() }
                return .init(section: .prompt(current))
            case .between(let left, let right):
                guard let first = id(left), let second = id(right) else { return .init() }
                return gap(first, second)
            case .before(let index):
                guard let current = id(index) else { return .init() }
                return .init(section: .before(current), isApproximate: true)
            case .after(let index):
                guard let current = id(index) else { return .init() }
                return .init(section: .after(current), isApproximate: true)
            }
        }
        guard evidence.allowsFrameEstimate else { return .init() }
        let visible = frames.compactMap { item -> (id: String, frame: CGRect?)? in
            guard confidentIDs.contains(item.id), known.contains(item.id),
                  let frame = item.frame, valid(frame), frame.intersects(evidence.viewport) else { return nil }
            return item
        }
        // Chromium can clamp offscreen frames to the viewport. Overlapping
        // prompt rectangles cannot establish a dependable current location.
        let sorted = visible.sorted { $0.frame!.minY < $1.frame!.minY }
        for pair in zip(sorted, sorted.dropFirst()) {
            if pair.0.frame!.intersection(pair.1.frame!).height > 2 { return .init() }
        }
        var tracker = ConversationLocationTracker()
        var estimate = tracker.locate(orderedIDs: orderedIDs, observations: visible,
                                      viewport: evidence.viewport, scrollFraction: nil)
        if case .between(let left, let right) = estimate.section { estimate = gap(left, right) }
        if case .prompt(let current) = estimate.section { estimate.section = .near(current) }
        if estimate.section != .unknown { estimate.isApproximate = true }
        return estimate
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }
}
