import XCTest
@testable import ChatGPTNavigator

final class IndexPaginationTests: XCTestCase {
    private func sample(
        _ visible: Int = 1, fraction: Double? = 0.5,
        loaded: Int = 100, busy: Bool = false
    ) -> IndexPageEvidence {
        .init(scrollFraction: fraction, visibleFingerprint: visible,
              loadedFingerprint: loaded, isBusy: busy)
    }

    func testSingleUnchangedFractionDoesNotStopPass() {
        var policy = IndexPaginationPolicy()
        XCTAssertEqual(policy.observe(sample(), elapsed: 0), .advance)
        XCTAssertEqual(policy.observe(sample(), elapsed: 0.35), .waitForHistory)
        XCTAssertEqual(policy.observe(sample(2), elapsed: 1), .advance)
    }

    func testLoadedTopRetriesPastThreeChecksThenResumesOnPagination() {
        var policy = IndexPaginationPolicy()
        XCTAssertEqual(policy.observe(sample(fraction: 0), elapsed: 0), .advance)
        for second in 1...5 {
            XCTAssertEqual(policy.observe(sample(fraction: 0), elapsed: Double(second)), .waitForHistory)
        }
        XCTAssertEqual(policy.observe(sample(2, fraction: 0.3, loaded: 101), elapsed: 6), .advance)
        XCTAssertEqual(policy.stalledChecks, 0)
        XCTAssertEqual(policy.observe(sample(3, fraction: 0.2, loaded: 101), elapsed: 6.5), .advance)
    }

    func testLongAssistantResponseContinuesWithoutNewPromptOrText() {
        var policy = IndexPaginationPolicy()
        // Only geometry changes while moving through one long text element.
        for page in 0..<30 {
            XCTAssertEqual(policy.observe(sample(page), elapsed: Double(page) * 0.4), .advance)
        }
    }

    func testRebasedScrollbarDoesNotLookLikeEndOfHistory() {
        var policy = IndexPaginationPolicy()
        _ = policy.observe(sample(1, fraction: 0.1), elapsed: 0)
        XCTAssertEqual(policy.observe(sample(2, fraction: 0.8, loaded: 102), elapsed: 1), .advance)
    }

    func testNewLoadedContentCanResumeEvenWithSameViewport() {
        var policy = IndexPaginationPolicy()
        _ = policy.observe(sample(fraction: 0), elapsed: 0)
        _ = policy.observe(sample(fraction: 0), elapsed: 4)
        XCTAssertEqual(policy.observe(sample(fraction: 0, loaded: 101), elapsed: 7), .advance)
        XCTAssertEqual(policy.observe(sample(fraction: 0, loaded: 101), elapsed: 8), .waitForHistory)
    }

    func testStableLoadedTopHasUnverifiedRatherThanCompleteOutcome() {
        var policy = IndexPaginationPolicy()
        _ = policy.observe(sample(fraction: 0), elapsed: 0)
        XCTAssertEqual(policy.observe(sample(fraction: 0), elapsed: 7), .waitForHistory)
        XCTAssertEqual(policy.observe(sample(fraction: 0), elapsed: 8), .stop(.stableLoadedTop))
        XCTAssertTrue(IndexPaginationPolicy.StopReason.stableLoadedTop.message.contains("not confirmed"))
    }

    func testBusyBoundaryWaitsLongerAndNeverClaimsCompletion() {
        var policy = IndexPaginationPolicy()
        _ = policy.observe(sample(fraction: 0, busy: true), elapsed: 0)
        XCTAssertEqual(policy.observe(sample(fraction: 0, busy: true), elapsed: 8), .waitForHistory)
        XCTAssertEqual(policy.observe(sample(fraction: 0, busy: true), elapsed: 15), .stop(.loadingTimedOut))
    }

    func testOscillationBetweenOldViewsIsNotProgress() {
        var policy = IndexPaginationPolicy()
        _ = policy.observe(sample(1), elapsed: 0)
        _ = policy.observe(sample(2), elapsed: 1)
        for second in 2..<9 {
            XCTAssertEqual(policy.observe(sample(second.isMultiple(of: 2) ? 1 : 2), elapsed: Double(second)), .waitForHistory)
        }
        XCTAssertEqual(policy.observe(sample(2), elapsed: 9), .stop(.stalled))
    }

    func testTemporarilyMissingAXTreeCanRecover() {
        var policy = IndexPaginationPolicy()
        XCTAssertEqual(policy.observe(nil, elapsed: 0), .waitForHistory)
        XCTAssertEqual(policy.observe(nil, elapsed: 3), .waitForHistory)
        XCTAssertEqual(policy.observe(sample(), elapsed: 3.5), .advance)
    }

    func testMissingOrEmptyAXTreeTimesOutAsPartial() {
        var policy = IndexPaginationPolicy()
        _ = policy.observe(nil, elapsed: 0)
        let empty = IndexPageEvidence(scrollFraction: 0, visibleFingerprint: nil, loadedFingerprint: nil, isBusy: false)
        XCTAssertEqual(policy.observe(empty, elapsed: 4), .stop(.accessibilityUnavailable))
    }

    func testTimeAndScanBoundsApplyEvenDuringProgress() {
        var timePolicy = IndexPaginationPolicy()
        XCTAssertEqual(timePolicy.observe(sample(), elapsed: 180), .stop(.timeLimit))
        var scanPolicy = IndexPaginationPolicy()
        for index in 0..<800 {
            XCTAssertEqual(scanPolicy.observe(sample(index), elapsed: Double(index) / 10), .advance)
        }
        XCTAssertEqual(scanPolicy.observe(sample(800), elapsed: 80), .stop(.scanLimit))
    }

    func testShortBurstCadenceIsFixedDuringProgressAndRetries() {
        var policy = IndexPaginationPolicy()
        _ = policy.observe(sample(), elapsed: 0)
        XCTAssertEqual(policy.delayMilliseconds, 190)
        _ = policy.observe(sample(), elapsed: 0.35)
        XCTAssertEqual(policy.delayMilliseconds, 190)
        _ = policy.observe(sample(), elapsed: 1)
        XCTAssertEqual(policy.delayMilliseconds, 190)
        _ = policy.observe(sample(2), elapsed: 2)
        XCTAssertEqual(policy.delayMilliseconds, 190)
    }
}
