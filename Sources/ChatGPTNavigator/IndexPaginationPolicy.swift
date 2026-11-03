import Foundation

struct IndexPageEvidence: Hashable {
    let scrollFraction: Double?
    let visibleFingerprint: Int?
    let loadedFingerprint: Int?
    let isBusy: Bool
}

struct IndexPaginationPolicy {
    enum StopReason: Equatable {
        case stableLoadedTop
        case stalled
        case loadingTimedOut
        case accessibilityUnavailable
        case timeLimit
        case scanLimit
        case inputInterrupted
        case inputUnavailable

        var message: String {
            switch self {
            case .stableLoadedTop:
                return "Reached a stable top of loaded history; full history is not confirmed."
            case .stalled:
                return "Partial pass: scrolling stopped making progress."
            case .loadingTimedOut:
                return "Partial pass: older history did not finish loading."
            case .accessibilityUnavailable:
                return "Partial pass: conversation Accessibility data became unavailable."
            case .timeLimit:
                return "Partial pass: the indexing time limit was reached."
            case .scanLimit:
                return "Partial pass: the indexing scan limit was reached."
            case .inputInterrupted:
                return "Indexing stopped because you switched apps or moved the pointer."
            case .inputUnavailable:
                return "Partial pass: mouse-wheel scrolling could not be started."
            }
        }
    }

    enum Decision: Equatable {
        case advance
        case waitForHistory
        case stop(StopReason)
    }

    private struct ViewState: Hashable {
        let fractionBucket: Int?
        let visible: Int?
        let loaded: Int?
    }

    let stallTimeout: TimeInterval = 8
    let loadingTimeout: TimeInterval = 15
    let accessibilityTimeout: TimeInterval = 4
    let maximumDuration: TimeInterval = 180
    // Half the travel per burst needs twice the scans for the same scroll range.
    let maximumScans = 800
    private var visited = Set<ViewState>()
    private var lastProgressAt: TimeInterval = 0
    private var missingSince: TimeInterval?
    private(set) var scans = 0
    private(set) var stalledChecks = 0

    var delayMilliseconds: Int {
        190
    }

    mutating func observe(_ sample: IndexPageEvidence?, elapsed: TimeInterval) -> Decision {
        if elapsed >= maximumDuration { return .stop(.timeLimit) }
        if scans >= maximumScans { return .stop(.scanLimit) }
        scans += 1
        guard let sample,
              sample.visibleFingerprint != nil || sample.loadedFingerprint != nil else {
            if missingSince == nil { missingSince = elapsed }
            stalledChecks += 1
            if elapsed - missingSince! >= accessibilityTimeout {
                return .stop(.accessibilityUnavailable)
            }
            return .waitForHistory
        }
        missingSince = nil

        let fraction = sample.scrollFraction.flatMap {
            $0.isFinite ? Int(min(1, max(0, $0)) * 100_000) : nil
        }
        let state = ViewState(
            fractionBucket: fraction,
            visible: sample.visibleFingerprint,
            loaded: sample.loadedFingerprint
        )
        if visited.insert(state).inserted {
            lastProgressAt = elapsed
            stalledChecks = 0
            return .advance
        }

        // Repeated A/B/A/B positions are not fresh progress either. Neither an
        // unchanged fraction nor an iteration without new prompts ends a pass.
        stalledChecks += 1
        let idle = elapsed - lastProgressAt
        if sample.isBusy {
            return idle >= loadingTimeout ? .stop(.loadingTimedOut) : .waitForHistory
        }
        if idle >= stallTimeout {
            if let fraction = sample.scrollFraction, fraction.isFinite, fraction <= 0.001 {
                return .stop(.stableLoadedTop)
            }
            return .stop(.stalled)
        }
        return .waitForHistory
    }
}
