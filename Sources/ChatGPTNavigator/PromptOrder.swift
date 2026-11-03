import Foundation

/// Each scan joins overlapping regions, but only fresh frame evidence supplies
/// before/after relationships. Disconnected regions keep their discovery order
/// at the end of the rail until a shared prompt connects them.
struct PromptOrder {
    private(set) var ids: [String] = []
    private(set) var groups: [[String]] = []
    private(set) var isProvisional = false
    private var relations: [Pair: Relation] = [:]
    private var revision = 0

    private struct Pair: Hashable {
        let low: String
        let high: String

        init(_ first: String, _ second: String) {
            low = min(first, second)
            high = max(first, second)
        }
    }

    private struct Relation {
        var before: String
        var after: String
        var confirmations = 1
        var decidedAt: Int
        var contraryConfirmations = 0
    }

    mutating func merge(
        _ observedIDs: [String], verifiedOrder: [String] = [],
        automaticPassOrder: [String] = []
    ) {
        revision += 1
        let page = unique(observedIDs)
        var registered = Set(ids)
        let newIDs = page.filter { registered.insert($0).inserted }
        let verified = unique(verifiedOrder).filter { registered.contains($0) }
        let automatic = unique(automaticPassOrder).filter { registered.contains($0) }
        let scanned = Set(page + verified + automatic)
        let touched = groups.indices.filter { !scanned.isDisjoint(with: groups[$0]) }

        if let first = touched.first {
            // Preserve every remembered row until relative positions are known.
            let members = Set(touched.flatMap { groups[$0] })
            let combined = ids.filter { members.contains($0) } + newIDs
            for index in touched.reversed() { groups.remove(at: index) }
            groups.insert(combined, at: first)
        } else if !newIDs.isEmpty {
            groups.append(newIDs)
        }
        ids = groups.flatMap { $0 }

        // Record each observed pair, not adjacency: A before C says nothing
        // about whether an unexposed B belongs between them.
        for index in verified.indices {
            for later in verified.dropFirst(index + 1) {
                let earlier = verified[index]
                let pair = Pair(earlier, later)
                if var relation = relations[pair] {
                    if relation.before == earlier {
                        relation.contraryConfirmations = 0
                        if relation.confirmations < 3 {
                            relation.confirmations += 1
                            if relation.confirmations == 3 { relation.decidedAt = revision }
                        }
                    } else {
                        relation.contraryConfirmations += 1
                        // A single transitional AX frame cannot flip a relation.
                        if relation.contraryConfirmations >= 3 {
                            relation = Relation(
                                before: earlier, after: later,
                                confirmations: 3, decidedAt: revision
                            )
                        }
                    }
                    relations[pair] = relation
                } else {
                    relations[pair] = Relation(before: earlier, after: later, decidedAt: revision)
                }
            }
        }
        // Explicit scan-direction evidence from an automatic pass can connect
        // disjoint regions and correct old provisional relationships. It only
        // supplies before/after edges: later recovery can insert missed prompts.
        // Ordinary manual refreshes never take this path.
        for index in automatic.indices {
            for later in automatic.dropFirst(index + 1) {
                let earlier = automatic[index]
                relations[Pair(earlier, later)] = Relation(
                    before: earlier, after: later,
                    confirmations: 3, decidedAt: revision
                )
            }
        }
        reconcile()
    }

    private mutating func reconcile() {
        // Rebuild chronology strongest evidence first. Repeated later evidence
        // can displace a contradictory stale path; equal evidence breaks ties
        // deterministically so unrelated refreshes cannot shuffle the rail.
        let evidence = relations.values.sorted {
            if $0.confirmations != $1.confirmations { return $0.confirmations > $1.confirmations }
            if $0.decidedAt != $1.decidedAt { return $0.decidedAt > $1.decidedAt }
            if $0.before != $1.before { return $0.before < $1.before }
            return $0.after < $1.after
        }
        var edges: [String: Set<String>] = [:]
        for relation in evidence {
            if !hasPath(from: relation.after, to: relation.before, edges: edges) {
                edges[relation.before, default: []].insert(relation.after)
            }
        }

        let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var sortedGroups: [[String]] = []
        var hasAmbiguity = groups.count > 1
        for group in groups {
            let members = Set(group)
            var incoming = Dictionary(uniqueKeysWithValues: group.map { ($0, 0) })
            for first in group {
                for second in edges[first] ?? [] where members.contains(second) {
                    incoming[second, default: 0] += 1
                }
            }
            var remaining = members
            var sorted: [String] = []
            while !remaining.isEmpty {
                let ready = remaining.filter { incoming[$0] == 0 }
                if ready.count > 1 { hasAmbiguity = true }
                guard let next = ready.min(by: { ranks[$0]! < ranks[$1]! }) else {
                    sorted.append(contentsOf: group.filter { remaining.contains($0) })
                    hasAmbiguity = true
                    break
                }
                sorted.append(next)
                remaining.remove(next)
                for following in edges[next] ?? [] where members.contains(following) {
                    incoming[following, default: 0] -= 1
                }
            }
            sortedGroups.append(sorted)
        }
        groups = sortedGroups
        ids = groups.flatMap { $0 }
        isProvisional = hasAmbiguity
    }

    private func hasPath(from start: String, to target: String, edges: [String: Set<String>]) -> Bool {
        var pending = [start]
        var visited = Set<String>()
        while let id = pending.popLast() {
            if id == target { return true }
            if visited.insert(id).inserted { pending.append(contentsOf: edges[id] ?? []) }
        }
        return false
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    mutating func reset() {
        ids.removeAll()
        groups.removeAll()
        relations.removeAll()
        revision = 0
        isProvisional = false
    }
}
