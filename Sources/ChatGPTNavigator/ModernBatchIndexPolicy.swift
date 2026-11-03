import Foundation

struct ModernIndexEvidence: Sendable {
    let leadingFingerprint: Int?
    let visibleFingerprint: Int?
    let isBusy: Bool
    let isTruncated: Bool
    var scrollFraction: Double? = nil
}

/// No backend cursor is exposed. A stable boundary is an apparent end, never
/// proof of complete server history. Streaming tail changes do not reset it.
struct ModernBatchIndexPolicy {
    enum Phase { case seekingEnd, upward }
    enum Stop: Equatable {
        case apparentBeginning, truncated, timeLimit, scanLimit, missingData, loadingTimedOut
        var message: String {
            switch self {
            case .apparentBeginning: return "Reached a stable loaded beginning; complete history is unverified."
            case .truncated: return "Partial index: a loaded section exceeded the Accessibility scan limit."
            case .timeLimit: return "Partial index: the six-minute time limit was reached."
            case .scanLimit: return "Partial index: the scan limit was reached."
            case .missingData: return "Partial index: conversation data became unavailable."
            case .loadingTimedOut: return "Partial index: history loading did not settle."
            }
        }
    }
    enum Decision: Equatable { case advance, wait, beginUpward, stop(Stop) }
    private struct State: Hashable { let leading: Int?; let visible: Int?; let fraction: Int? }
    private(set) var phase: Phase = .seekingEnd
    private(set) var scans = 0
    private(set) var sections = 0
    private var visited = Set<State>()
    private var leadingSections = Set<Int>()
    private var lastProgressAt: TimeInterval = 0
    private var missingSince: TimeInterval?
    private var sawTruncation = false

    mutating func observe(_ sample: ModernIndexEvidence?, elapsed: TimeInterval) -> Decision {
        if elapsed >= 343 { return .stop(.timeLimit) }
        if scans >= 900 { return .stop(.scanLimit) }
        scans += 1
        guard let sample, sample.leadingFingerprint != nil || sample.visibleFingerprint != nil else {
            if missingSince == nil { missingSince = elapsed }
            return elapsed - missingSince! >= 4 ? .stop(.missingData) : .wait
        }
        missingSince = nil
        sawTruncation = sawTruncation || sample.isTruncated
        if let leading = sample.leadingFingerprint, leadingSections.insert(leading).inserted { sections += 1 }
        let bucket = sample.scrollFraction.flatMap { $0.isFinite ? Int(min(1, max(0, $0)) * 10_000) : nil }
        let state = State(leading: sample.leadingFingerprint, visible: sample.visibleFingerprint, fraction: bucket)
        if visited.insert(state).inserted {
            lastProgressAt = elapsed
            return .advance
        }
        let idle = elapsed - lastProgressAt
        if sample.isBusy { return idle >= 15 ? .stop(.loadingTimedOut) : .wait }
        if phase == .seekingEnd, idle >= 2 {
            phase = .upward
            visited.removeAll()
            lastProgressAt = elapsed
            return .beginUpward
        }
        if phase == .upward, idle >= 8 {
            return .stop(sawTruncation ? .truncated : .apparentBeginning)
        }
        return .wait
    }
}
