import CoreGraphics
import XCTest
@testable import ChatGPTNavigator

final class ConversationLocationTests: XCTestCase {
    private let viewport = CGRect(x: 100, y: 100, width: 600, height: 600)
    private func frame(_ y: CGFloat, height: CGFloat = 50) -> CGRect {
        CGRect(x: 200, y: y, width: 400, height: height)
    }

    func testViewportMidpointInsidePrompt() {
        var tracker = ConversationLocationTracker()
        let result = tracker.locate(
            orderedIDs: ["a", "b"], observations: [("a", frame(370))],
            viewport: viewport, scrollFraction: 0.5
        )
        XCTAssertEqual(result.section, .prompt("a"))
        XCTAssertFalse(result.isApproximate)
        XCTAssertEqual(result.highlightedID, "a")
    }

    func testExactGapUsesBothFreshAdjacentBoundaries() {
        var tracker = ConversationLocationTracker()
        let result = tracker.locate(
            orderedIDs: ["a", "b"],
            observations: [("b", frame(600)), ("a", frame(200))],
            viewport: viewport, scrollFraction: 0.5
        )
        XCTAssertEqual(result.section, .between("a", "b"))
        XCTAssertFalse(result.isApproximate)
        XCTAssertEqual(result.markerBeforeID, "b")
        XCTAssertEqual(result.label(in: ["a", "b"]), "Between prompts 1 and 2")
    }

    func testOneBoundaryProducesApproximateSection() {
        var tracker = ConversationLocationTracker()
        let result = tracker.locate(
            orderedIDs: ["a", "b"], observations: [("a", frame(200))],
            viewport: viewport, scrollFraction: 0.5
        )
        XCTAssertEqual(result.section, .between("a", "b"))
        XCTAssertTrue(result.isApproximate)
    }

    func testFollowingBoundaryInfersPreviousRememberedPrompt() {
        var tracker = ConversationLocationTracker()
        let result = tracker.locate(
            orderedIDs: ["a", "b"], observations: [("b", frame(600))],
            viewport: viewport, scrollFraction: 0.5
        )
        XCTAssertEqual(result.section, .between("a", "b"))
        XCTAssertTrue(result.isApproximate)
    }

    func testNonAdjacentLoadedPromptsCannotClaimExactGap() {
        var tracker = ConversationLocationTracker()
        let result = tracker.locate(
            orderedIDs: ["a", "b", "c"],
            observations: [("a", frame(200)), ("c", frame(600))],
            viewport: viewport, scrollFraction: 0.5
        )
        XCTAssertTrue(result.isApproximate)
    }

    func testEmptyViewportUsesExplicitApproximationThenResets() {
        var tracker = ConversationLocationTracker()
        _ = tracker.locate(
            orderedIDs: ["a"], observations: [("a", frame(370))],
            viewport: viewport, scrollFraction: 0.5
        )
        let estimated = tracker.locate(
            orderedIDs: ["a"], observations: [],
            viewport: viewport, scrollFraction: 0.6
        )
        XCTAssertEqual(estimated.section, .near("a"))
        XCTAssertTrue(estimated.isApproximate)
        tracker.reset()
        XCTAssertEqual(tracker.locate(
            orderedIDs: ["a"], observations: [],
            viewport: viewport, scrollFraction: 0.6
        ).section, .unknown)
    }

    func testMissingViewportAndInvalidFramesCannotClaimLocation() {
        var tracker = ConversationLocationTracker()
        XCTAssertEqual(tracker.locate(
            orderedIDs: ["a"], observations: [("a", frame(370))],
            viewport: nil, scrollFraction: nil
        ).section, .unknown)
        XCTAssertEqual(tracker.locate(
            orderedIDs: ["a"], observations: [("a", .zero)],
            viewport: viewport, scrollFraction: nil
        ).section, .unknown)
    }

    func testBeforeAndAfterRememberedPrompts() {
        var tracker = ConversationLocationTracker()
        let before = tracker.locate(
            orderedIDs: ["a"], observations: [("a", frame(600))],
            viewport: viewport, scrollFraction: nil
        )
        XCTAssertEqual(before.section, .before("a"))
        XCTAssertEqual(before.markerBeforeID, "a")
        let after = tracker.locate(
            orderedIDs: ["a"], observations: [("a", frame(200))],
            viewport: viewport, scrollFraction: nil
        )
        XCTAssertEqual(after.section, .after("a"))
        XCTAssertEqual(after.markerAfterID, "a")
    }
}
