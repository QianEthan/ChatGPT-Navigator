import ApplicationServices
import Foundation
import Testing
@testable import ChatGPTNavigator

struct ModernRecoveryTests {
    private func context(route: String? = "route-A") -> ModernConversationContext {
        .init(processID: 42, windowID: "window", regionID: "region", title: "Equal title", conversationID: route)
    }

    @Test func persistentRouteLossStopsShowingOldRowsAsCurrent() {
        var memory = ModernPromptMemory()
        memory.observe([.init(text: "Old chat")], in: context(), now: 0)
        let initial = memory.observe([.init(text: "New chat")], in: context(route: nil), now: 1)
        #expect(initial.mode == .paused)
        let expired = memory.observe([.init(text: "New chat")], in: context(route: nil), now: 5)
        #expect(expired.mode == .snapshotOnly)
        #expect(expired.didReset)
        #expect(memory.context == nil)
        #expect(memory.records.isEmpty)
        for time in 6...100 {
            let next = memory.observe([.init(text: "New chat")], in: context(route: nil), now: Double(time))
            #expect(next.mode == .snapshotOnly)
            #expect(memory.records.isEmpty)
        }
        let recovered = memory.observe([.init(text: "New chat")], in: context(route: "route-B"), now: 101)
        #expect(recovered.mode == .remembering)
        #expect(memory.records.values.map(\.text) == ["New chat"])
    }

    @Test func disjointOrdinaryFallbackViewsCannotMixTwoChats() {
        var memory = ModernPromptMemory()
        memory.observe([.init(text: "Old chat")], in: context(route: nil), allowDisjointFallback: false)
        let update = memory.observe([.init(text: "Other chat")], in: context(route: nil), allowDisjointFallback: false)
        #expect(update.didReset)
        #expect(memory.records.values.map(\.text) == ["Other chat"])
    }

    @Test func verifiedRoutesAndExplicitIndexingKeepDisjointHistory() {
        for (route, indexing) in [("route-A" as String?, false), (nil, true)] {
            var memory = ModernPromptMemory()
            memory.observe([.init(text: "First section")], in: context(route: route), allowDisjointFallback: indexing)
            let update = memory.observe([.init(text: "Second section")], in: context(route: route), allowDisjointFallback: indexing)
            #expect(!update.didReset)
            #expect(memory.records.count == 2)
        }
    }

    @Test func readBudgetStopsAtDeadlineAndDoesNotResume() {
        var budget = ModernReadBudget(duration: 2, now: 10)
        let check1 = budget.allowRead(now: 11.99)
        #expect(check1)
        let check2 = !budget.allowRead(now: 12)
        #expect(check2)
        #expect(budget.failure == .deadline)
        let check3 = !budget.allowRead(now: 11)
        #expect(check3)
    }

    @Test func unsupportedAttributesCannotHideTransportFailureOrCauseDisconnect() {
        var healthy = ModernReadBudget(duration: 2, now: 0)
        for _ in 0..<100 { healthy.record(.attributeUnsupported) }
        let check4 = healthy.allowRead(now: 1)
        #expect(check4)
        healthy.record(.cannotComplete)
        healthy.record(.attributeUnsupported)
        healthy.record(.invalidUIElement)
        healthy.record(.noValue)
        healthy.record(.cannotComplete)
        let check5 = !healthy.allowRead(now: 1)
        #expect(check5)
        #expect(healthy.failure == .transportUnavailable)
        var cancelled = ModernReadBudget(duration: 2, now: 0)
        let check6 = !cancelled.allowRead(now: 0, cancelled: true)
        #expect(check6)
        #expect(cancelled.failure == .cancelled)
    }

    @Test func rendererActivationRetriesFailureWithBackoff() {
        var recovery = ModernRendererRecovery()
        let check7 = recovery.shouldRequest(identity: "process", now: 0)
        #expect(check7)
        recovery.didRequest(succeeded: false, now: 0)
        let check8 = !recovery.shouldRequest(identity: "process", now: 1)
        #expect(check8)
        let check9 = recovery.shouldRequest(identity: "process", now: 2)
        #expect(check9)
        recovery.didRequest(succeeded: true, now: 2)
        recovery.observedContent(available: true, now: 3)
        let check10 = !recovery.shouldRequest(identity: "process", now: 100)
        #expect(check10)
        recovery.observedContent(available: false, now: 101)
        let check11 = !recovery.shouldRequest(identity: "process", now: 102)
        #expect(check11)
        let check12 = recovery.shouldRequest(identity: "process", now: 104)
        #expect(check12)
        let check13 = recovery.shouldRequest(identity: "restarted-process", now: 104)
        #expect(check13)
        #expect(recovery.attempts == 0)
    }
}

// Fake synchronous IPC lets these tests exercise executor and cancellation
// behavior without requesting Accessibility access or interacting with chats.
private final class BlockingRead: @unchecked Sendable {
    let started: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation
    private let lock = NSLock()
    let release = DispatchSemaphore(value: 0)
    private let failOnSecond: Bool
    private var count = 0
    private var active = 0
    private(set) var maxActive = 0
    private(set) var ranOnMainThread = false
    private(set) var sawCancellation = false

    init(failOnSecond: Bool = false) {
        self.failOnSecond = failOnSecond
        let stream = AsyncStream<Int>.makeStream()
        started = stream.stream
        continuation = stream.continuation
    }

    func read(_ options: ModernScanOptions, _ cancellation: ModernReadCancellation) -> ConversationSnapshot? {
        let index = lock.withLock {
            count += 1
            active += 1
            maxActive = max(maxActive, active)
            ranOnMainThread = ranOnMainThread || Thread.isMainThread
            return count
        }
        continuation.yield(index)
        // A timeout ensures a broken test can fail rather than hang the suite.
        _ = release.wait(timeout: .now() + 2)
        lock.withLock { active -= 1; sawCancellation = sawCancellation || cancellation.isCancelled }
        if failOnSecond, index == 2 {
            return .init(entries: [], chatWindowFrame: nil, usedStructuralOwnership: false,
                         diagnosticLines: ["scan-stopped=deadline"], modernScanFailure: "deadline")
        }
        let text = index == 1 ? "Old chat prompt" : "New chat prompt"
        let context = ModernConversationContext(processID: 42, windowID: "window", regionID: "region", title: text, conversationID: "route-\(index)")
        let entry = NavigationEntry(id: "entry-\(index)", preview: text, fullText: text, confidence: .userMessage,
            sourceRole: "AXHeading", element: AXUIElementCreateApplication(42), frame: nil, scrollFraction: nil)
        return .init(entries: [entry], chatWindowFrame: nil, usedStructuralOwnership: true,
                     diagnosticLines: [], modernContext: context)
    }
}

@MainActor
struct ModernWorkerTests {
    private func settle(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    @Test func aBlockedReadLeavesMainActorResponsiveAndCancelledResultsAreDiscarded() async {
        let fake = BlockingRead()
        let worker = ModernAXWorker(testRead: fake.read)
        let task = Task { await worker.scan() }
        var iterator = fake.started.makeAsyncIterator()
        _ = await iterator.next()
        // This main-actor code can execute before the fake IPC call completes.
        #expect(!fake.ranOnMainThread)
        task.cancel()
        fake.release.signal()
        let result = await task.value
        #expect(result == nil)
        #expect(fake.sawCancellation)
    }

    @Test func readerIsSerializedAndCancelledQueuedWorkNeverReads() async {
        let fake = BlockingRead()
        let worker = ModernAXWorker(testRead: fake.read)
        let first = Task { await worker.scan() }
        var iterator = fake.started.makeAsyncIterator()
        _ = await iterator.next()
        let queued = Task { await worker.scan() }
        await Task.yield()
        queued.cancel()
        fake.release.signal()
        _ = await first.value
        #expect(await queued.value == nil)
        #expect(fake.maxActive == 1)
        let third = Task { await worker.scan() }
        #expect(await iterator.next() == 2)
        fake.release.signal()
        #expect(await third.value != nil)
        #expect(fake.maxActive == 1)
    }

    @Test func unavailableSnapshotsNeverMarkRememberedRowsAsConnected() async {
        let fake = BlockingRead(failOnSecond: true)
        let client = ModernAccessibilityClient(worker: ModernAXWorker(testRead: fake.read))
        let model = NavigatorModel(modernAccessibility: client, modernTrustCheck: { true })
        var iterator = fake.started.makeAsyncIterator()
        model.refresh()
        _ = await iterator.next()
        fake.release.signal()
        await settle { model.modernConnectionReady }
        #expect(model.entries.count == 1)
        model.refresh()
        _ = await iterator.next()
        fake.release.signal()
        await settle { model.state == .reconnecting }
        #expect(!model.modernConnectionReady)
        #expect(model.entries.count == 1)
        #expect(model.modernMemoryWarning != nil)
        model.stop()
    }

    @Test func anOldPointerCleanupCannotRevokeANewerOperation() {
        let old = ModernInputLease()
        let newer = ModernInputLease()
        #expect(!old.isCurrent)
        old.release()
        #expect(newer.isCurrent)
        newer.release()
        #expect(!newer.isCurrent)
    }

    @Test func repeatedRefreshesAreCoalescedAndReconnectRejectsTheOldResult() async {
        let fake = BlockingRead()
        let client = ModernAccessibilityClient(worker: ModernAXWorker(testRead: fake.read))
        let model = NavigatorModel(modernAccessibility: client, modernTrustCheck: { true })
        for _ in 0..<20 { model.refresh() }
        var iterator = fake.started.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        model.reconnectModernConversation()
        fake.release.signal()
        #expect(await iterator.next() == 2)
        #expect(model.entries.isEmpty)
        #expect(!model.modernConnectionReady)
        fake.release.signal()
        await settle { model.modernConnectionReady }
        #expect(model.entries.map(\.fullText) == ["New chat prompt"])
        #expect(model.state == .ready)
        #expect(fake.maxActive == 1)
        model.stop()
    }
}
