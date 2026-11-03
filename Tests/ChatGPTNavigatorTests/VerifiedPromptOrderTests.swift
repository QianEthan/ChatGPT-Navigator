import CoreGraphics
import XCTest
@testable import ChatGPTNavigator

final class VerifiedPromptOrderTests: XCTestCase {
    func testEvidenceUsesFreshVerticalPositionInsteadOfTextOrDiscoveryOrder() {
        let evidence = PromptOrderEvidence(observations: [
            ("alphabetically-first", CGRect(x: 100, y: 600, width: 500, height: 100)),
            ("alphabetically-last", CGRect(x: 100, y: 100, width: 500, height: 100))
        ])
        XCTAssertEqual(evidence.orderedIDs, ["alphabetically-last", "alphabetically-first"])
    }

    func testMissingFrameDoesNotInventAdjacency() {
        let evidence = PromptOrderEvidence(observations: [
            ("a", CGRect(x: 100, y: 100, width: 500, height: 100)),
            ("b", nil),
            ("c", CGRect(x: 100, y: 600, width: 500, height: 100))
        ])
        var order = PromptOrder()
        order.merge(["a", "b", "c"], verifiedOrder: ["a", "b", "c"])
        order.merge(["a", "b", "c"], verifiedOrder: evidence.orderedIDs)
        XCTAssertEqual(order.ids, ["a", "b", "c"])
    }

    func testOverlappingZeroAndNonfiniteFramesCannotProveChronology() {
        let shared = CGRect(x: 100, y: 100, width: 500, height: 100)
        let overlap = PromptOrderEvidence(observations: [("a", shared), ("b", shared)])
        XCTAssertTrue(overlap.orderedIDs.isEmpty)
        let invalid = PromptOrderEvidence(observations: [
            ("a", .zero), ("b", .null),
            ("c", CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100))
        ])
        XCTAssertTrue(invalid.orderedIDs.isEmpty)
    }
}
