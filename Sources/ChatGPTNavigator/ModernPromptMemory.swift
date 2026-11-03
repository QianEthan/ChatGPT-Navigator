import Foundation

struct ModernConversationContext: Equatable, Sendable {
    let processID: Int32
    let windowID: String
    let regionID: String
    let title: String
    let conversationID: String?

    var sessionKey: String? {
        let identity: String
        if let conversationID {
            identity = "conversation:\(conversationID)"
        } else {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !["", "chatgpt", "codex", "new chat"].contains(name.lowercased()) else { return nil }
            identity = "title:\(name)\u{1F}region:\(regionID)"
        }
        return "\(processID)\u{1F}\(windowID)\u{1F}\(identity)"
    }

    /// Accept a conversation route, not a generic app page or a linked website.
    static func conversationID(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              !["file", "about", "data", "chrome", "chrome-extension"].contains(scheme) else { return nil }
        let markers: Set<String> = ["c", "chat", "chats", "conversation", "conversations", "thread", "threads", "task", "tasks", "local", "remote"]
        func valid(_ value: String) -> Bool {
            value.count >= 12 && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let paths = [url.path, components?.fragment ?? ""]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            for index in parts.indices where index + 1 < parts.count {
                if markers.contains(parts[index].lowercased()), valid(parts[index + 1]) {
                    return "\(url.scheme ?? "")://\(url.host ?? "")/\(parts[index].lowercased())/\(parts[index + 1])"
                }
            }
        }
        for item in components?.queryItems ?? [] {
            if ["conversationid", "threadid"].contains(item.name.lowercased()),
               let value = item.value, valid(value) {
                return "\(url.scheme ?? "")://\(url.host ?? "")/\(item.name.lowercased())/\(value)"
            }
        }
        return nil
    }

    static func messageID(from domID: String) -> String? {
        guard let range = domID.range(
            of: #"^(?:(?:conversation-)?turn|(?:user-)?message)[-_:]"#,
            options: .regularExpression
        ) else { return nil }
        let value = String(domID[range.upperBound...])
        let opaque = value.count >= 16 && value.contains(where: \.isLetter) &&
            value.contains(where: \.isNumber) &&
            value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        guard UUID(uuidString: value) != nil || opaque else { return nil }
        return domID
    }
}

struct ModernPromptObservation {
    let text: String
    var nativeID: String? = nil
}

/// Session-only message memory. Viewport ordinals and AX element handles are
/// never durable identities. Observed order adds before/after edges, not claims
/// of global adjacency. Disjoint sections stay provisional until they overlap.
struct ModernPromptMemory {
    struct Record {
        let id: String
        var text: String
        var key: String
        var nativeID: String?
    }
    enum Mode { case remembering, paused, snapshotOnly }
    struct Update {
        let mode: Mode
        let didReset: Bool
        let observedIDs: [String]
        var confidentIDs: Set<String> = []
    }

    private(set) var context: ModernConversationContext?
    private(set) var records: [String: Record] = [:]
    private(set) var orderedIDs: [String] = []
    private(set) var groups: [[String]] = []
    private(set) var isProvisional = false
    private(set) var hasAmbiguousRepeats = false
    private var discoveryOrder: [String] = []
    private var edges: [String: Set<String>] = [:]
    private var nativeIDs: [String: String] = [:]
    private var nextID = 0
    private var hasOrderConflict = false
    private var identityMissingSince: TimeInterval?
    private var unverifiedScope: ModernConversationContext?


    mutating func reset() { self = Self() }

    @discardableResult
    mutating func observe(
        _ observations: [ModernPromptObservation],
        in incoming: ModernConversationContext,
        allowDisjointFallback: Bool = true,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Update {
        if let unverifiedScope, incoming.conversationID == nil,
           Self.sameFallbackScope(unverifiedScope, incoming) {
            return Update(mode: .snapshotOnly, didReset: false, observedIDs: [])
        }
        // A temporarily missing URL must not merge a new unverified selection
        // into memory which was established using a stronger conversation ID.
        if let previous = context, previous.conversationID != nil, incoming.conversationID == nil,
           previous.processID == incoming.processID, previous.windowID == incoming.windowID,
           previous.regionID == incoming.regionID, previous.title == incoming.title {
            if identityMissingSince == nil { identityMissingSince = now }
            if now - identityMissingSince! >= 4 {
                reset()
                unverifiedScope = previous
                return Update(mode: .snapshotOnly, didReset: true, observedIDs: [])
            }
            return Update(mode: .paused, didReset: false, observedIDs: [])
        }
        identityMissingSince = nil
        unverifiedScope = nil
        guard let key = incoming.sessionKey else {
            reset()
            return Update(mode: .snapshotOnly, didReset: true, observedIDs: [])
        }
        var didReset = context?.sessionKey != key
        // Without a route, an entirely disjoint view cannot distinguish a chat
        // switch from a large scroll. Ordinary discovery starts fresh; an
        // explicitly verified indexing pass may retain disjoint sections.
        if !didReset, !allowDisjointFallback, incoming.conversationID == nil,
           !observations.isEmpty, !records.isEmpty {
            let knownText = Set(records.values.map(\.key))
            let hasOverlap = observations.contains {
                knownText.contains(Self.canonical($0.text)) || $0.nativeID.flatMap { nativeIDs[$0] } != nil
            }
            if !hasOverlap { didReset = true }
        }
        if didReset { reset() }
        context = incoming
        let keys = observations.map { Self.canonical($0.text) }
        let counts = Dictionary(grouping: keys, by: { $0 }).mapValues(\.count)
        let nativeCounts = Dictionary(grouping: observations.compactMap(\.nativeID), by: { $0 }).mapValues(\.count)
        var knownByText = Dictionary(grouping: orderedIDs, by: { records[$0]!.key })
        let ranks = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        var assigned = [String?](repeating: nil, count: observations.count)
        var confident = [Bool](repeating: false, count: observations.count)
        var used = Set<String>()
        hasAmbiguousRepeats = false

        func eligible(_ index: Int) -> [String] {
            (knownByText[keys[index]] ?? []).filter { !used.contains($0) }
        }
        func uniqueNative(_ index: Int) -> String? {
            guard let value = observations[index].nativeID, nativeCounts[value] == 1 else { return nil }
            return value
        }
        // Resolve native identities and unique text anchors before repeated
        // content, so neighbors can disambiguate identical prompts.
        for index in observations.indices {
            guard assigned[index] == nil, !keys[index].isEmpty else { continue }
            if let native = uniqueNative(index) {
                let id: String
                if let known = nativeIDs[native], !used.contains(known) {
                    id = known
                } else {
                    let unkeyed = eligible(index).filter { records[$0]?.nativeID == nil }
                    if unkeyed.count == 1, counts[keys[index]] == 1 { id = unkeyed[0] }
                    else { id = insert(observations[index].text, key: keys[index], nativeID: native) }
                }
                assigned[index] = id
                confident[index] = true
                used.insert(id)
                records[id]?.key = keys[index]
            }
        }
        knownByText = Dictionary(grouping: discoveryOrder, by: { records[$0]!.key })
        for index in observations.indices where assigned[index] == nil && !keys[index].isEmpty {
            if let known = knownByText[keys[index]], known.count == 1,
               counts[keys[index]] == 1, !used.contains(known[0]) {
                assigned[index] = known[0]
                confident[index] = true
                used.insert(known[0])
            }
        }
        for index in observations.indices where assigned[index] == nil && !keys[index].isEmpty {
            let candidates = eligible(index)
            let left = observations.indices.prefix(index).reversed().compactMap { assigned[$0].flatMap { ranks[$0] } }.first
            let right = observations.indices.dropFirst(index + 1).compactMap { assigned[$0].flatMap { ranks[$0] } }.first
            let bounded = candidates.filter { id in
                guard let rank = ranks[id] else { return false }
                return (left == nil || rank > left!) && (right == nil || rank < right!)
            }
            let knownCount = knownByText[keys[index]]?.count ?? 0
            let allKnownVisible = knownCount == counts[keys[index]]
            let chosen = bounded.first ?? candidates.first
            if let chosen {
                assigned[index] = chosen
                confident[index] = (bounded.count == 1 && (left != nil || right != nil)) || allKnownVisible
                if !confident[index] { hasAmbiguousRepeats = true }
                used.insert(chosen)
            } else {
                let id = insert(observations[index].text, key: keys[index])
                assigned[index] = id
                confident[index] = knownCount == 0
                if !confident[index] { hasAmbiguousRepeats = true }
                used.insert(id)
            }
        }
        for index in observations.indices {
            guard let id = assigned[index] else { continue }
            records[id]?.text = observations[index].text
            records[id]?.key = keys[index]
            if let native = uniqueNative(index) {
                records[id]?.nativeID = native
                nativeIDs[native] = id
            }
        }
        let verified = observations.indices.compactMap { confident[$0] ? assigned[$0] : nil }
        for (before, after) in zip(verified, verified.dropFirst()) where before != after {
            if edges[before]?.contains(after) == true { continue }
            if reaches(before, from: after) { hasOrderConflict = true }
            else { edges[before, default: []].insert(after) }
        }
        reconcile()
        let observedIDs = assigned.map { $0 ?? "" }
        return Update(mode: .remembering, didReset: didReset, observedIDs: observedIDs,
                      confidentIDs: Set(verified))
    }

    private static func sameFallbackScope(_ lhs: ModernConversationContext, _ rhs: ModernConversationContext) -> Bool {
        lhs.processID == rhs.processID && lhs.windowID == rhs.windowID &&
            lhs.regionID == rhs.regionID && lhs.title == rhs.title
    }

    private static func canonical(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private mutating func insert(_ text: String, key: String, nativeID: String? = nil) -> String {
        nextID += 1
        let id = "remembered:\(nextID)"
        records[id] = Record(id: id, text: text, key: key, nativeID: nativeID)
        discoveryOrder.append(id)
        return id
    }
    private func reaches(_ target: String, from start: String) -> Bool {
        var pending = [start]
        var seen = Set<String>()
        while let id = pending.popLast() {
            if id == target { return true }
            if seen.insert(id).inserted { pending.append(contentsOf: edges[id] ?? []) }
        }
        return false
    }
    private mutating func reconcile() {
        let registered = Set(orderedIDs)
        let previous = orderedIDs + discoveryOrder.filter { !registered.contains($0) }
        let ranks = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element, $0.offset) })
        var neighbors: [String: Set<String>] = [:]
        for (before, following) in edges {
            for after in following {
                neighbors[before, default: []].insert(after)
                neighbors[after, default: []].insert(before)
            }
        }
        var visited = Set<String>()
        var result: [[String]] = []
        var ambiguous = hasOrderConflict || hasAmbiguousRepeats
        for seed in previous where !visited.contains(seed) {
            var pending = [seed]
            var component = Set<String>()
            while let id = pending.popLast() {
                if component.insert(id).inserted { pending.append(contentsOf: neighbors[id] ?? []) }
            }
            visited.formUnion(component)
            var incoming = Dictionary(uniqueKeysWithValues: component.map { ($0, 0) })
            for id in component {
                for after in edges[id] ?? [] { incoming[after, default: 0] += 1 }
            }
            var ready = Set(component.filter { incoming[$0] == 0 })
            var sorted: [String] = []
            while let id = ready.min(by: { ranks[$0]! < ranks[$1]! }) {
                if ready.count > 1 { ambiguous = true }
                ready.remove(id)
                sorted.append(id)
                for after in edges[id] ?? [] {
                    incoming[after, default: 0] -= 1
                    if incoming[after] == 0 { ready.insert(after) }
                }
            }
            result.append(sorted)
        }
        groups = result
        orderedIDs = result.flatMap { $0 }
        isProvisional = ambiguous || result.count > 1
    }
}
