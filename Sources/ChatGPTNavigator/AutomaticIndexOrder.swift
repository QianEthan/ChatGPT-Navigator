import Foundation

/// Lifetime: one uninterrupted, app-controlled upward indexing pass. Unlike
/// manual discovery, an all-new viewport is encountered above the last one.
/// Empty reply-only viewports preserve the frontier across arbitrarily long gaps.
struct AutomaticIndexOrder {
    private(set) var ids: [String] = []

    @discardableResult
    mutating func observe(_ orderedIDs: [String]) -> [String] {
        var unique = Set<String>()
        let page = orderedIDs.filter { unique.insert($0).inserted }
        let known = Set(ids)
        var cursor = 0

        while cursor < page.count {
            guard !known.contains(page[cursor]) else {
                cursor += 1
                continue
            }
            let start = cursor
            while cursor < page.count, !known.contains(page[cursor]) { cursor += 1 }
            let run = Array(page[start..<cursor])
            let insertion: Int
            if cursor < page.count, let next = ids.firstIndex(of: page[cursor]) {
                insertion = next
            } else if start > 0, let previous = ids.firstIndex(of: page[start - 1]) {
                insertion = previous + 1
            } else {
                // No shared prompt is required across a long assistant reply:
                // this code is called only for our own upward pulse sequence.
                insertion = 0
            }
            ids.insert(contentsOf: run, at: insertion)
        }
        return ids
    }
}
