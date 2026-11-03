import XCTest
@testable import ChatGPTNavigator

final class AutomaticIndexOrderTests: XCTestCase {
    func testLongReplyGapPreservesUpwardFrontier() {
        var pass = AutomaticIndexOrder()
        XCTAssertEqual(pass.observe(["newer"]), ["newer"])
        for _ in 0..<30 { XCTAssertEqual(pass.observe([]), ["newer"]) }
        XCTAssertEqual(pass.observe(["older"]), ["older", "newer"])
    }

    func testDisjointBatchesPreserveWithinPageReadingOrder() {
        var pass = AutomaticIndexOrder()
        pass.observe(["d", "e"])
        pass.observe(["b", "c"])
        XCTAssertEqual(pass.observe(["a"]), ["a", "b", "c", "d", "e"])
    }

    func testRepeatedPagesDoNotInsertDuplicatesOrChangeOrder() {
        var pass = AutomaticIndexOrder()
        pass.observe(["c", "d"])
        pass.observe(["a", "b", "c"])
        XCTAssertEqual(pass.observe(["c", "d", "d"]), ["a", "b", "c", "d"])
        XCTAssertEqual(pass.observe(["a", "b"]), ["a", "b", "c", "d"])
    }

    func testLateRenderCanInsertMissingPromptAtItsObservedNeighbors() {
        var pass = AutomaticIndexOrder()
        pass.observe(["a", "c"])
        XCTAssertEqual(pass.observe(["a", "b", "c"]), ["a", "b", "c"])
        XCTAssertEqual(pass.observe(["c", "d"]), ["a", "b", "c", "d"])
    }

    func testAutomaticPassConnectsDisjointGroupsWithoutPendingOrder() {
        var order = PromptOrder()
        var pass = AutomaticIndexOrder()
        order.merge(["newer"], verifiedOrder: ["newer"], automaticPassOrder: pass.observe(["newer"]))
        for _ in 0..<20 { order.merge([], automaticPassOrder: pass.observe([])) }
        order.merge(["older"], verifiedOrder: ["older"], automaticPassOrder: pass.observe(["older"]))
        XCTAssertEqual(order.ids, ["older", "newer"])
        XCTAssertEqual(order.groups.count, 1)
        XCTAssertFalse(order.isProvisional)
    }

    func testEquivalentManualDiscoveryStillStaysPending() {
        var order = PromptOrder()
        order.merge(["newer"], verifiedOrder: ["newer"])
        for _ in 0..<20 { order.merge([]) }
        order.merge(["older"], verifiedOrder: ["older"])
        XCTAssertEqual(order.groups, [["newer"], ["older"]])
        XCTAssertTrue(order.isProvisional)
    }

    func testPreviouslyDiscoveredManualSectionsAreRepairedByAutoPass() {
        var order = PromptOrder()
        order.merge(["a", "b", "c"], verifiedOrder: ["a", "b", "c"])
        let actual = ["b", "c", "a"]
        order.merge(actual, verifiedOrder: actual, automaticPassOrder: actual)
        XCTAssertEqual(order.ids, actual)
        XCTAssertFalse(order.isProvisional)
    }

    func testMissedPromptCanBeRecoveredManuallyWithoutBreakingAutoOrder() {
        var order = PromptOrder()
        order.merge(["a", "c"], verifiedOrder: ["a", "c"], automaticPassOrder: ["a", "c"])
        order.merge(["a", "b", "c"], verifiedOrder: ["a", "b", "c"])
        XCTAssertEqual(order.ids, ["a", "b", "c"])
        XCTAssertFalse(order.isProvisional)
    }

    func testNewPassDoesNotReuseOldFrontierAndDoesNotOrderUnreachedPrompts() {
        var order = PromptOrder()
        order.merge(["outside-pass"])
        var firstPass = AutomaticIndexOrder()
        order.merge(["newer"], automaticPassOrder: firstPass.observe(["newer"]))
        order.merge(["older"], automaticPassOrder: firstPass.observe(["older"]))
        XCTAssertTrue(order.isProvisional)
        XCTAssertEqual(order.groups, [["outside-pass"], ["older", "newer"]])
        var newPass = AutomaticIndexOrder()
        XCTAssertEqual(newPass.observe(["unrelated"]), ["unrelated"])
    }
}
