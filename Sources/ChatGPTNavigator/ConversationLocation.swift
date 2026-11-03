import CoreGraphics
import Foundation

struct ConversationLocation: Equatable {
    enum Section: Equatable {
        case unknown
        case prompt(String)
        case between(String, String)
        case before(String)
        case after(String)
        case near(String)
    }

    var section: Section = .unknown
    var isApproximate = false

    var highlightedID: String? {
        switch section {
        case .prompt(let id), .near(let id): return id
        default: return nil
        }
    }

    var markerBeforeID: String? {
        switch section {
        case .between(_, let id), .before(let id): return id
        default: return nil
        }
    }

    var markerAfterID: String? {
        if case .after(let id) = section { return id }
        return nil
    }

    func label(in orderedIDs: [String], numbersAreProvisional: Bool = false) -> String {
        func number(_ id: String) -> String {
            guard let index = orderedIDs.firstIndex(of: id) else { return "?" }
            return "\(numbersAreProvisional ? "~" : "")\(index + 1)"
        }
        let text: String
        switch section {
        case .unknown: return "Location unavailable"
        case .prompt(let id): text = "At prompt \(number(id))"
        case .between(let first, let second):
            text = "Between prompts \(number(first)) and \(number(second))"
        case .before(let id): text = "Before prompt \(number(id))"
        case .after(let id): text = "After prompt \(number(id))"
        case .near(let id): text = "Near prompt \(number(id))"
        }
        return isApproximate ? "Approx. · \(text)" : text
    }
}

/// Uses only frames from the latest scan. Saved scrollbar observations are
/// used for a clearly approximate fallback, never as exact message boundaries.
struct ConversationLocationTracker {
    private var rememberedFractions: [String: Double] = [:]

    mutating func locate(
        orderedIDs: [String],
        observations: [(id: String, frame: CGRect?)],
        viewport: CGRect?,
        scrollFraction: Double?
    ) -> ConversationLocation {
        guard let viewport, !viewport.isNull, !viewport.isEmpty else { return .init() }
        let known = Set(orderedIDs)
        let frames = observations.compactMap { observation -> (id: String, frame: CGRect)? in
            guard known.contains(observation.id), let frame = observation.frame,
                  !frame.isNull, !frame.isEmpty,
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.maxX > viewport.minX, frame.minX < viewport.maxX else { return nil }
            return (observation.id, frame)
        }.sorted { $0.frame.minY < $1.frame.minY }
        if let scrollFraction, scrollFraction.isFinite {
            for observation in frames where observation.frame.intersects(viewport) {
                rememberedFractions[observation.id] = scrollFraction
            }
        }

        let midpoint = viewport.midY
        if let current = frames.first(where: {
            $0.frame.minY <= midpoint && $0.frame.maxY >= midpoint
        }) {
            return .init(section: .prompt(current.id))
        }
        let preceding = frames.last(where: { $0.frame.maxY < midpoint })
        let following = frames.first(where: { $0.frame.minY > midpoint })
        if let preceding, let following,
           let lower = orderedIDs.firstIndex(of: preceding.id),
           let upper = orderedIDs.firstIndex(of: following.id), upper == lower + 1 {
            return .init(section: .between(preceding.id, following.id))
        }
        if let preceding, let index = orderedIDs.firstIndex(of: preceding.id) {
            if index + 1 < orderedIDs.count {
                return .init(
                    section: .between(preceding.id, orderedIDs[index + 1]),
                    isApproximate: true
                )
            }
            return .init(section: .after(preceding.id), isApproximate: true)
        }
        if let following, let index = orderedIDs.firstIndex(of: following.id) {
            if index > 0 {
                return .init(
                    section: .between(orderedIDs[index - 1], following.id),
                    isApproximate: true
                )
            }
            return .init(section: .before(following.id), isApproximate: true)
        }
        if let scrollFraction, scrollFraction.isFinite,
           let nearest = orderedIDs.filter({ rememberedFractions[$0] != nil }).min(by: {
               abs(rememberedFractions[$0]! - scrollFraction) <
                   abs(rememberedFractions[$1]! - scrollFraction)
           }) {
            return .init(section: .near(nearest), isApproximate: true)
        }
        return .init()
    }

    mutating func reset() { rememberedFractions.removeAll() }
}
