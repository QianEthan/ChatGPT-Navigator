import CoreGraphics

struct PromptOrderEvidence {
    let orderedIDs: [String]

    init(observations: [(id: String, frame: CGRect?)]) {
        var seen = Set<String>()
        let framed = observations.compactMap { item -> (id: String, frame: CGRect)? in
            guard seen.insert(item.id).inserted, let frame = item.frame,
                  !frame.isNull, !frame.isEmpty,
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { return nil }
            return (item.id, frame)
        }.sorted { $0.frame.minY < $1.frame.minY }

        // Shared, overlapping, or transitional frames cannot prove chronology.
        // Omit ambiguous elements rather than treating alphabetical order as
        // temporal evidence.
        let reliable = framed.enumerated().filter { index, item in
            let clearAbove = index == 0 || framed[index - 1].frame.maxY <= item.frame.minY
            let clearBelow = index + 1 == framed.count || item.frame.maxY <= framed[index + 1].frame.minY
            return clearAbove && clearBelow
        }.map(\.element)
        orderedIDs = reliable.map(\.id)
    }
}
