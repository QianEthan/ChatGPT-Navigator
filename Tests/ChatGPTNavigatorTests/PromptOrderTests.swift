import XCTest
@testable import ChatGPTNavigator

final class PromptOrderTests: XCTestCase {
    func testSinglePromptRefreshesCannotShuffleKnownOrder() {
        var order = PromptOrder()
        order.merge(["a", "b", "c"], verifiedOrder: ["a", "b", "c"])
        for _ in 0..<10 {
            order.merge(["c"])
            order.merge(["a"])
            order.merge(["b"])
        }
        XCTAssertEqual(order.ids, ["a", "b", "c"])
        XCTAssertFalse(order.isProvisional)
    }

    func testOlderAndNewerOverlapsSupplyChronology() {
        var order = PromptOrder()
        order.merge(["c", "d"], verifiedOrder: ["c", "d"])
        order.merge(["a", "b", "c"], verifiedOrder: ["a", "b", "c"])
        order.merge(["d", "e", "f"], verifiedOrder: ["d", "e", "f"])
        XCTAssertEqual(order.ids, ["a", "b", "c", "d", "e", "f"])
        XCTAssertFalse(order.isProvisional)
    }

    func testDiscoveryWithoutFramesRemainsProvisional() {
        var order = PromptOrder()
        order.merge(["a", "b", "c"])
        order.merge(["c", "a", "b"])
        XCTAssertEqual(order.ids, ["a", "b", "c"])
        XCTAssertTrue(order.isProvisional)
    }

    func testDisconnectedOlderPagesNeverInsertIntoThirdPosition() {
        var order = PromptOrder()
        let known = (1...10).map { "p\($0)" }
        order.merge(known, verifiedOrder: known)
        // No normalized fraction is accepted by the ordering API anymore.
        order.merge(["older"])
        order.merge(["evenOlder", "older"], verifiedOrder: ["evenOlder", "older"])
        XCTAssertEqual(order.ids, known + ["evenOlder", "older"])
        XCTAssertEqual(order.groups, [known, ["evenOlder", "older"]])
        XCTAssertTrue(order.isProvisional)
        order.merge(["older", "p1"], verifiedOrder: ["older", "p1"])
        XCTAssertEqual(order.ids, ["evenOlder", "older"] + known)
        XCTAssertEqual(order.groups.count, 1)
        XCTAssertFalse(order.isProvisional)
    }

    func testTwentyPromptConversationDiscoveredInDisconnectedBatches() {
        var order = PromptOrder()
        let newer = (11...20).map { "p\($0)" }
        let older = (1...10).map { "p\($0)" }
        order.merge(newer, verifiedOrder: newer)
        order.merge(older, verifiedOrder: older)
        XCTAssertEqual(order.groups, [newer, older])
        XCTAssertTrue(order.isProvisional)
        order.merge(["p10", "p11"], verifiedOrder: ["p10", "p11"])
        XCTAssertEqual(order.ids, older + newer)
        XCTAssertFalse(order.isProvisional)
    }

    func testCoVisibleDoesNotMeanAdjacent() {
        var order = PromptOrder()
        order.merge(["a", "b", "c"], verifiedOrder: ["a", "b", "c"])
        // B temporarily disappears from the AX hierarchy.
        order.merge(["a", "c"], verifiedOrder: ["a", "c"])
        XCTAssertEqual(order.ids, ["a", "b", "c"])
        XCTAssertFalse(order.isProvisional)
    }

    func testPartialScanDoesNotCompressUnverifiedRowsEither() {
        var order = PromptOrder()
        order.merge(["a", "b", "c", "d", "e"])
        order.merge(["a", "e"], verifiedOrder: ["a", "e"])
        XCTAssertEqual(order.ids, ["a", "b", "c", "d", "e"])
        XCTAssertTrue(order.isProvisional)
        let actual = ["b", "c", "d", "a", "e"]
        order.merge(actual, verifiedOrder: actual)
        XCTAssertEqual(order.ids, actual)
        XCTAssertFalse(order.isProvisional)
    }

    func testNewMessageCanFillGapWithoutForcingAdjacency() {
        var order = PromptOrder()
        order.merge(["a", "d"], verifiedOrder: ["a", "d"])
        order.merge(["a", "b", "c", "d"], verifiedOrder: ["a", "b", "c", "d"])
        XCTAssertEqual(order.ids, ["a", "b", "c", "d"])
    }

    func testOneContraryScanCannotFlipOrderButThreeCanCorrectIt() {
        var order = PromptOrder()
        order.merge(["a", "b"], verifiedOrder: ["a", "b"])
        order.merge(["b", "a"], verifiedOrder: ["b", "a"])
        XCTAssertEqual(order.ids, ["a", "b"])
        order.merge(["b", "a"], verifiedOrder: ["b", "a"])
        XCTAssertEqual(order.ids, ["a", "b"])
        order.merge(["b", "a"], verifiedOrder: ["b", "a"])
        XCTAssertEqual(order.ids, ["b", "a"])
    }

    func testSupportingObservationResetsContraryStreak() {
        var order = PromptOrder()
        order.merge(["a", "b"], verifiedOrder: ["a", "b"])
        for _ in 0..<5 {
            order.merge(["b", "a"], verifiedOrder: ["b", "a"])
            order.merge(["a", "b"], verifiedOrder: ["a", "b"])
        }
        XCTAssertEqual(order.ids, ["a", "b"])
    }

    func testRepeatedNewEvidenceCanOverrideConflictingTransitivePath() {
        var order = PromptOrder()
        for _ in 0..<3 { order.merge(["a", "b", "c"], verifiedOrder: ["a", "b", "c"]) }
        for _ in 0..<3 { order.merge(["c", "a"], verifiedOrder: ["c", "a"]) }
        XCTAssertLessThan(order.ids.firstIndex(of: "c")!, order.ids.firstIndex(of: "a")!)
        XCTAssertEqual(Set(order.ids), Set(["a", "b", "c"]))
        for _ in 0..<3 { order.merge(["c", "a", "b"], verifiedOrder: ["c", "a", "b"]) }
        XCTAssertEqual(order.ids, ["c", "a", "b"])
    }

    func testDuplicateEmptyAndUnknownEvidenceDoNotLoseOrCreateRows() {
        var order = PromptOrder()
        order.merge(["a", "a", "b"], verifiedOrder: ["a", "a", "b", "unregistered"])
        order.merge([])
        XCTAssertEqual(order.ids, ["a", "b"])
        XCTAssertEqual(order.groups, [["a", "b"]])
    }

    func testResetClearsRelationshipsAndPendingSections() {
        var order = PromptOrder()
        order.merge(["a", "b"], verifiedOrder: ["a", "b"])
        order.merge(["x"])
        order.reset()
        order.merge(["b", "a"], verifiedOrder: ["b", "a"])
        XCTAssertEqual(order.ids, ["b", "a"])
        XCTAssertFalse(order.isProvisional)
    }

    func testAllDiscoveryOrdersOfOverlappingPagesConverge() {
        func permutations(_ values: [Int]) -> [[Int]] {
            if values.isEmpty { return [[]] }
            return values.flatMap { first in
                permutations(values.filter { $0 != first }).map { [first] + $0 }
            }
        }
        let actual = ["a", "b", "c", "d", "e", "f"]
        let pages = (0..<5).map { Array(actual[$0...($0 + 1)]) }
        for sequence in permutations(Array(pages.indices)) {
            var order = PromptOrder()
            for index in sequence { order.merge(pages[index], verifiedOrder: pages[index]) }
            XCTAssertEqual(order.ids, actual, "Page discovery order: \(sequence)")
            XCTAssertFalse(order.isProvisional)
        }
    }
}
