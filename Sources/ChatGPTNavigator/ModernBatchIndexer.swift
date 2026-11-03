import AppKit
import ApplicationServices

/// One explicit indexing pass. All transcript capture goes through the same
/// scoped parser/memory as ordinary discovery; there is no parallel transcript.
@MainActor
final class ModernBatchIndexer {
    private let client: ModernAccessibilityClient
    init(client: ModernAccessibilityClient) {
        self.client = client
    }
    private enum Failure: Error {
        case changedChat, inputInterrupted, unavailable, noScrollPoint
        var message: String {
            switch self {
            case .changedChat: return "Indexing stopped because the conversation or window changed."
            case .inputInterrupted: return "Indexing stopped because you moved the pointer or switched apps."
            case .unavailable: return "Partial index: conversation Accessibility data became unavailable."
            case .noScrollPoint: return "Partial index: no unobstructed conversation scroll area was found."
            }
        }
    }

    func run(context: ModernConversationContext,
             capture: (ConversationSnapshot) -> Void,
             progress: (String) -> Void) async -> String {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: ModernAccessibilityClient.bundleIdentifier
        ).first, app.processIdentifier == context.processID,
              let originalPointer = CGEvent(source: nil)?.location else {
            return Failure.unavailable.message
        }
        var input: Input?
        var policy = ModernBatchIndexPolicy()
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer { input?.end() }
        do {
            _ = try await checkedSnapshot(context)
            app.activate(options: [])
            try await Task.sleep(for: .milliseconds(180))
            var fresh = try await checkedSnapshot(context, frontmost: true)
            guard let point = fresh.modernScrollPoint else { throw Failure.noScrollPoint }
            let ownedInput = try Input(pid: context.processID, original: originalPointer, point: point)
            input = ownedInput
            var reason = ModernBatchIndexPolicy.Stop.timeLimit
            while true {
                try Task.checkCancellation()
                guard ownedInput.isActive else { throw Failure.inputInterrupted }
                fresh = try await checkedSnapshot(context, frontmost: true)
                capture(fresh)
                let decision = policy.observe(fresh.modernIndexEvidence,
                                              elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
                if case .stop(let stopped) = decision { reason = stopped; break }
                let upward = policy.phase == .upward
                progress("\(upward ? "Indexing upward" : "Moving to newest messages") · \(policy.sections) sections · \(policy.scans) scans")
                // Indexing is continuous wheel traversal. Every loaded
                // section is captured before the next burst; no Find query can
                // jump past intermediate sections or bounce on repeated text.
                guard let point = fresh.modernScrollPoint else { throw Failure.noScrollPoint }
                try ownedInput.repark(at: point)
                if fresh.modernIndexEvidence?.isBusy != true {
                    try await ownedInput.scroll(upward: upward)
                }
                // New sections are captured promptly. At quiet boundaries we
                // keep polling/retrying, allowing delayed older batches to load.
                try await Task.sleep(for: .milliseconds(decision == .advance ? 257 : 429))
            }
            return "\(policy.sections) loaded sections scanned. \(reason.message)"
        } catch {
            if error is CancellationError { return "Indexing stopped. All discovered prompts were kept." }
            return (error as? Failure)?.message ?? "Partial index: scrolling could not continue."
        }
    }

    private func checkedSnapshot(_ context: ModernConversationContext,
                                 frontmost: Bool = false) async throws -> ConversationSnapshot {
        try Task.checkCancellation()
        if frontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier != context.processID {
            throw Failure.inputInterrupted
        }
        guard let fresh = await client.scan(includeIndexing: true, includeResponses: true) else { throw Failure.unavailable }
        guard let key = context.sessionKey, fresh.modernContext?.sessionKey == key else { throw Failure.changedChat }
        try Task.checkCancellation()
        if frontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier != context.processID { throw Failure.inputInterrupted }
        return fresh
    }

    /// Physical wheel input uses the same discrete notches as the working
    /// Classic indexer. User pointer movement or app switching relinquishes it.
    @MainActor
    private final class Input {
        let pid: pid_t
        let original: CGPoint
        var parked: CGPoint
        var ended = false
        private var lease: ModernInputLease?
        init(pid: pid_t, original: CGPoint, point: CGPoint) throws {
            self.pid = pid; self.original = original; parked = point
            guard let pointer = CGEvent(source: nil)?.location,
                  hypot(pointer.x - original.x, pointer.y - original.y) <= 8 else { throw Failure.inputInterrupted }
            guard belongsToApp(point), CGWarpMouseCursorPosition(point) == .success else { throw Failure.noScrollPoint }
            lease = ModernInputLease()
            postMove(point)
        }
        var isActive: Bool {
            guard !ended, lease?.isCurrent == true, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let pointer = CGEvent(source: nil)?.location,
                  hypot(pointer.x - parked.x, pointer.y - parked.y) <= 8 else { return false }
            return belongsToApp(parked)
        }
        func repark(at point: CGPoint) throws {
            guard isActive, belongsToApp(point) else { throw Failure.inputInterrupted }
            guard CGWarpMouseCursorPosition(point) == .success else { throw Failure.noScrollPoint }
            parked = point
            postMove(point)
        }
        func scroll(upward: Bool) async throws {
            for _ in 0..<6 {
                try Task.checkCancellation()
                guard isActive, let event = CGEvent(
                    scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                    wheel1: upward ? 12 : -12, wheel2: 0, wheel3: 0
                ) else { throw Failure.inputInterrupted }
                event.location = parked
                event.flags = []
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: .microseconds(21_429))
            }
        }
        func end() {
            guard !ended else { return }
            ended = true
            if lease?.isCurrent == true, let pointer = CGEvent(source: nil)?.location,
               hypot(pointer.x - parked.x, pointer.y - parked.y) <= 8 {
                _ = CGWarpMouseCursorPosition(original)
            }
            lease?.release()
        }
        private func belongsToApp(_ point: CGPoint) -> Bool {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return false }
            var actual: pid_t = 0
            return AXUIElementGetPid(hit, &actual) == .success && actual == pid
        }
        private func postMove(_ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}
