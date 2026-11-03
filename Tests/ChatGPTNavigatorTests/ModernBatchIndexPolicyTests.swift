import Testing
@testable import ChatGPTNavigator

struct ModernBatchIndexPolicyTests {
    private func sample(_ leading: Int = 1, visible: Int = 1, busy: Bool = false,
                        truncated: Bool = false, fraction: Double? = nil) -> ModernIndexEvidence {
        .init(leadingFingerprint: leading, visibleFingerprint: visible, isBusy: busy,
              isTruncated: truncated, scrollFraction: fraction)
    }
    private func upward() -> ModernBatchIndexPolicy {
        var policy = ModernBatchIndexPolicy()
        _ = policy.observe(sample(), elapsed: 0)
        _ = policy.observe(sample(), elapsed: 2.1)
        return policy
    }

    @Test func startsBySeekingTheNewestMessagesThenChangesDirection() {
        var policy = ModernBatchIndexPolicy()
        #expect(policy.phase == .seekingEnd)
        #expect(policy.observe(sample(), elapsed: 0) == .advance)
        #expect(policy.observe(sample(), elapsed: 1.5) == .wait)
        #expect(policy.observe(sample(), elapsed: 2.1) == .beginUpward)
        #expect(policy.phase == .upward)
    }
    @Test func changingVisibleReplyContentIsProgressWithoutAnyNewPrompt() {
        var policy = upward()
        #expect(policy.observe(sample(visible: 10), elapsed: 3) == .advance)
        #expect(policy.observe(sample(visible: 11), elapsed: 7) == .advance)
        #expect(policy.observe(sample(visible: 12), elapsed: 11) == .advance)
        #expect(policy.observe(sample(visible: 12), elapsed: 12) == .wait)
    }
    @Test func aDelayedOlderBatchResetsTheBoundaryWait() {
        var policy = upward()
        _ = policy.observe(sample(), elapsed: 2.2)
        #expect(policy.observe(sample(), elapsed: 8) == .wait)
        #expect(policy.observe(sample(2, visible: 2), elapsed: 9) == .advance)
        #expect(policy.observe(sample(2, visible: 2), elapsed: 16) == .wait)
        #expect(policy.observe(sample(2, visible: 2), elapsed: 17.1) == .stop(.apparentBeginning))
    }
    @Test func busyHistoryIsAllowedMoreTimeAndNeverCalledComplete() {
        var policy = upward()
        _ = policy.observe(sample(), elapsed: 3)
        #expect(policy.observe(sample(busy: true), elapsed: 12) == .wait)
        #expect(policy.observe(sample(busy: true), elapsed: 18.1) == .stop(.loadingTimedOut))
    }
    @Test func repeatedBouncePositionsAreNotEndlessNewProgress() {
        var policy = upward()
        _ = policy.observe(sample(1), elapsed: 3)
        _ = policy.observe(sample(2), elapsed: 4)
        #expect(policy.observe(sample(1), elapsed: 8) == .wait)
        #expect(policy.observe(sample(2), elapsed: 12.1) == .stop(.apparentBeginning))
    }
    @Test func truncatedSectionsRemainPartialEvenAtAStableBoundary() {
        var policy = upward()
        _ = policy.observe(sample(truncated: true), elapsed: 3)
        #expect(policy.observe(sample(), elapsed: 11.1) == .stop(.truncated))
    }
    @Test func missingAccessibilityDataHasABoundedRetry() {
        var policy = ModernBatchIndexPolicy()
        #expect(policy.observe(nil, elapsed: 0) == .wait)
        #expect(policy.observe(nil, elapsed: 3.9) == .wait)
        #expect(policy.observe(nil, elapsed: 4.1) == .stop(.missingData))
    }
    @Test func restoredDataClearsTheMissingDataTimer() {
        var policy = ModernBatchIndexPolicy()
        _ = policy.observe(nil, elapsed: 0)
        _ = policy.observe(sample(), elapsed: 2)
        #expect(policy.observe(nil, elapsed: 5) == .wait)
        #expect(policy.observe(sample(2), elapsed: 7) == .advance)
    }
    @Test func movementOfAnExposedScrollbarCountsAsProgress() {
        var policy = upward()
        #expect(policy.observe(sample(fraction: 0.8), elapsed: 3) == .advance)
        #expect(policy.observe(sample(fraction: 0.6), elapsed: 8) == .advance)
        #expect(policy.observe(sample(fraction: 0.6), elapsed: 14) == .wait)
    }
    @Test func timeAndScanLimitsAlwaysBoundThePass() {
        var policy = ModernBatchIndexPolicy()
        #expect(policy.observe(sample(), elapsed: 343) == .stop(.timeLimit))
        var limited = ModernBatchIndexPolicy()
        for index in 0..<900 { _ = limited.observe(sample(index), elapsed: Double(index) / 10) }
        #expect(limited.observe(sample(900), elapsed: 91) == .stop(.scanLimit))
    }
    @Test func repeatedSnapshotsDoNotInflateSectionCount() {
        var policy = ModernBatchIndexPolicy()
        _ = policy.observe(sample(1), elapsed: 0)
        _ = policy.observe(sample(1, visible: 2), elapsed: 0.2)
        _ = policy.observe(sample(2), elapsed: 0.4)
        _ = policy.observe(sample(1), elapsed: 0.6)
        #expect(policy.sections == 2)
    }
    @Test func overlappingLoadedBatchesRememberAllPromptsWithRepeatedText() {
        var memory = ModernPromptMemory()
        let context = ModernConversationContext(processID: 1, windowID: "w", regionID: "r", title: "Test", conversationID: nil)
        let text = ["Oldest", "Again", "Middle", "Again", "Newest"]
        let observations = text.enumerated().map { ModernPromptObservation(text: $0.element, nativeID: "message-\($0.offset)") }
        for batch in [Array(observations[2...4]), Array(observations[1...3]), Array(observations[0...2])] {
            memory.observe(batch, in: context)
        }
        #expect(memory.orderedIDs.compactMap { memory.records[$0]?.text } == text)
        #expect(memory.records.count == 5)
        #expect(ModernNavigationPolicy.matchingIndices(text: "Again", entries: observations) == [1, 3])
    }
}
