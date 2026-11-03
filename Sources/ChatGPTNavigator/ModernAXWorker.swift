import AppKit
import ApplicationServices
import Foundation

struct ModernScanOptions: Sendable {
    var location = false
    var indexing = false
    var diagnostics = false
    var responses = false
}

// The cancellation handler can run on any executor while a synchronous AX call
// is in flight. Only this flag is shared; the reader itself is actor-confined.
final class ModernReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct ModernReadBudget {
    enum Failure: String { case deadline, cancelled, transportUnavailable }
    let deadline: TimeInterval
    private(set) var failure: Failure?
    private var consecutiveFailures = 0

    init(duration: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        deadline = now + duration
    }

    mutating func allowRead(now: TimeInterval = ProcessInfo.processInfo.systemUptime, cancelled: Bool = false) -> Bool {
        if cancelled { failure = .cancelled }
        if failure == nil, now >= deadline { failure = .deadline }
        return failure == nil
    }

    mutating func record(_ error: AXError) {
        if error == .cannotComplete || error == .invalidUIElement {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 { failure = .transportUnavailable }
        } else if error == .success {
            consecutiveFailures = 0
        }
        // Unsupported attributes and no-value results are normal; they must
        // neither cause disconnection nor hide repeated transport failures.
    }
}

struct ModernRendererRecovery {
    private var identity: String?
    private var succeeded = false
    private var nextAttempt: TimeInterval = 0
    private var missingSince: TimeInterval?
    private(set) var attempts = 0

    mutating func shouldRequest(identity: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if self.identity != identity {
            self = Self()
            self.identity = identity
        }
        guard now >= nextAttempt else { return false }
        return !succeeded || missingSince.map { now - $0 >= 3 } == true
    }

    mutating func didRequest(succeeded: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.succeeded = succeeded
        attempts += 1
        nextAttempt = now + min(30, pow(2, Double(min(attempts, 5))))
    }

    mutating func observedContent(available: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if available {
            // A real Conversation landmark is stronger evidence than a setter
            // result. Do not keep re-enabling a renderer that is already live.
            succeeded = true
            missingSince = nil
        }
        else if missingSince == nil { missingSince = now }
    }
}

struct ModernConversationProbe: Sendable {
    let context: ModernConversationContext?
    let title: String?
}

// These CF objects are immutable retained references; all messaging remains on
// the worker. CFEqual on the main actor only compares reference identity.
struct ModernAXReference: @unchecked Sendable { let element: AXUIElement }
struct ModernFindField: @unchecked Sendable {
    let element: AXUIElement
    let value: String
    let diagnostics: [String]
}
struct ModernCopyTarget: @unchecked Sendable {
    let button: AXUIElement
    let nextPrompt: AXUIElement?
    let viewport: CGRect
    let bounds: CGRect
}

/// Serial actor executor, independent of MainActor. There is exactly one reader
/// for polling, navigation and export; cancellation is checked between AX calls.
actor ModernAXWorker {
    private let reader = ModernAccessibilityReader()
    private let testRead: (@Sendable (ModernScanOptions, ModernReadCancellation) -> ConversationSnapshot?)?

    init(testRead: (@Sendable (ModernScanOptions, ModernReadCancellation) -> ConversationSnapshot?)? = nil) {
        self.testRead = testRead
    }

    func scan(options: ModernScanOptions = .init()) async -> ConversationSnapshot? {
        let cancellation = ModernReadCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            let result: ConversationSnapshot?
            if let testRead { result = testRead(options, cancellation) }
            else { result = reader.read(options: options, cancellation: cancellation) }
            return Task.isCancelled ? nil : result
        } onCancel: { cancellation.cancel() }
    }

    func requestRecovery() { reader.requestRecovery() }

    func probe() async -> ModernConversationProbe? {
        let cancellation = ModernReadCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            let value = reader.probe(cancellation: cancellation)
            return Task.isCancelled ? nil : value
        } onCancel: { cancellation.cancel() }
    }

    func findField(pid: pid_t) async -> ModernFindField? {
        let cancellation = ModernReadCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            let value = reader.findField(pid: pid, cancellation: cancellation)
            return Task.isCancelled ? nil : value
        } onCancel: { cancellation.cancel() }
    }

    func copyTarget(entry: NavigationEntry, expected: ModernConversationContext) async -> ModernCopyTarget? {
        let cancellation = ModernReadCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            let result = reader.copyTarget(entry: entry, expected: expected, cancellation: cancellation)
            return Task.isCancelled ? nil : result
        } onCancel: { cancellation.cancel() }
    }

    func scrollToVisible(_ reference: ModernAXReference, expected: ModernConversationContext) -> Int32 {
        guard !Task.isCancelled else { return AXError.cannotComplete.rawValue }
        let cancellation = ModernReadCancellation()
        guard reader.probe(cancellation: cancellation)?.context?.sessionKey == expected.sessionKey,
              !Task.isCancelled else { return AXError.cannotComplete.rawValue }
        AXUIElementSetMessagingTimeout(reference.element, 0.15)
        return AXUIElementPerformAction(reference.element, "AXScrollToVisible" as CFString).rawValue
    }
}
