import CoreGraphics
import Testing
@testable import ChatGPTNavigator

struct ModernConversationLocationTests {
    private let viewport = CGRect(x: 100, y: 100, width: 600, height: 600)
    private func frame(_ y: CGFloat, height: CGFloat = 50) -> CGRect {
        CGRect(x: 200, y: y, width: 300, height: height)
    }
    private func n(_ role: String, _ text: String = "", _ depth: Int) -> ModernConversationNode {
        ModernConversationNode(role: role, text: text, depth: depth)
    }
    private var nodes: [ModernConversationNode] {
        [n("AXGroup", "", 0),
         n("AXStaticText", "Earlier reply", 1),
         n("AXHeading", "You said:", 1),
         n("AXGroup", "", 1), n("AXStaticText", "Question A", 2),
         n("AXHeading", "ChatGPT said:", 1),
         n("AXGroup", "", 1), n("AXStaticText", "Reply A", 2),
         n("AXHeading", "You said:", 1),
         n("AXGroup", "", 1), n("AXStaticText", "Question B", 2),
         n("AXHeading", "ChatGPT said:", 1),
         n("AXGroup", "", 1), n("AXStaticText", "Reply B", 2)]
    }
    private func anchor(_ index: Int) -> ModernLocationEvidence.Anchor? {
        ModernConversationLocation.anchor(at: index, nodes: nodes,
                                           prompts: ModernConversationParser.userPrompts(in: nodes))
    }
    private func locate(_ anchor: ModernLocationEvidence.Anchor?,
                        ids: [String] = ["a", "b"], confident: Set<String> = ["a", "b"],
                        ordered: [String] = ["a", "b"], groups: [[String]] = [["a", "b"]],
                        allowEstimate: Bool = true,
                        frames: [(id: String, frame: CGRect?)] = []) -> ConversationLocation {
        ModernConversationLocation.locate(
            evidence: .init(anchor: anchor, viewport: viewport, allowsFrameEstimate: allowEstimate),
            observedIDs: ids, confidentIDs: confident, orderedIDs: ordered, groups: groups, frames: frames
        )
    }

    @Test func hitInsidePromptTextOrBubbleIdentifiesThatPrompt() {
        #expect(anchor(3) == .prompt(0))
        #expect(anchor(4) == .prompt(0))
        #expect(anchor(10) == .prompt(1))
        let result = locate(.prompt(1))
        #expect(result.section == .prompt("b"))
        #expect(result.highlightedID == "b")
        #expect(!result.isApproximate)
    }

    @Test func replyMidpointBracketsNeighboringPrompts() {
        #expect(anchor(7) == .between(0, 1))
        let result = locate(anchor(7))
        #expect(result.section == .between("a", "b"))
        #expect(result.markerBeforeID == "b")
        #expect(result.isApproximate)
    }

    @Test func longFirstAndLastRepliesHaveExplicitSingleBoundaryLabels() {
        #expect(anchor(1) == .before(0))
        #expect(anchor(13) == .after(1))
        #expect(locate(anchor(1)).markerBeforeID == "a")
        #expect(locate(anchor(13)).markerAfterID == "b")
    }

    @Test func broadConversationContainerIsNotMistakenForItsFirstChild() {
        #expect(anchor(0) == nil)
        #expect(anchor(2) == nil) // speaker heading is metadata
        #expect(anchor(-1) == nil)
        #expect(anchor(1000) == nil)
    }

    @Test func streamingBodyRangeExcludesUnheadedStatusAndReply() {
        let streamed = [n("AXHeading", "You said:", 1), n("AXGroup", "", 1),
                        n("AXStaticText", "Prompt", 2), n("AXGroup", "", 1),
                        n("AXStaticText", "Working for 2m", 2)]
        let prompts = ModernConversationParser.userPrompts(in: streamed)
        #expect(prompts[0].bodyRange == 1..<3)
        #expect(ModernConversationLocation.anchor(at: 4, nodes: streamed, prompts: prompts) == .after(0))
        #expect(prompts[0].text == "Prompt")
    }

    @Test func viewportIndicesMapToRememberedIDsAfterEarlierPromptsAreDiscovered() {
        let result = locate(.prompt(0), ids: ["a", "b"],
                            ordered: ["older", "a", "b"], groups: [["older", "a", "b"]])
        #expect(result.section == .prompt("a"))
        #expect(result.label(in: ["older", "a", "b"]) == "At prompt 2")
        #expect(result.label(in: ["older", "a", "b"], numbersAreProvisional: true) == "At prompt ~2")
    }

    @Test func disconnectedOrderGroupsDoNotProduceABetweenMarker() {
        let result = locate(.between(0, 1), groups: [["a"], ["b"]])
        #expect(result.section == .near("a"))
        #expect(result.markerBeforeID == nil)
        #expect(result.isApproximate)
    }

    @Test func ambiguousRepeatedPromptDoesNotGetAFalseCurrentMarker() {
        #expect(locate(.prompt(0), confident: []).section == .unknown)
        #expect(locate(.between(0, 1), confident: ["a"]).section == .unknown)
        #expect(locate(.prompt(9)).section == .unknown)
    }

    @Test func missingOrOccludedViewClearsLocationEvenWhenFramesExist() {
        #expect(locate(nil, allowEstimate: false, frames: [("a", frame(370))]).section == .unknown)
        #expect(ModernConversationLocation.locate(
            evidence: nil, observedIDs: ["a"], confidentIDs: ["a"], orderedIDs: ["a"],
            groups: [["a"]], frames: [("a", frame(370))]
        ).section == .unknown)
        #expect(locate(nil).section == .unknown)
    }

    @Test func freshCoordinatesAreOnlyAnApproximateFallback() {
        let result = locate(nil, frames: [("a", frame(370))])
        #expect(result.section == .near("a"))
        #expect(result.isApproximate)
        #expect(locate(nil, frames: [("a", frame(-200))]).section == .unknown)
        #expect(locate(nil, frames: [("a", .zero)]).section == .unknown)
    }

    @Test func overlappingClampedFramesCannotCreateALocation() {
        #expect(locate(nil, frames: [("a", frame(370)), ("b", frame(370))]).section == .unknown)
    }

    @Test func freshHitTakesPriorityOverIncorrectCoordinates() {
        let result = locate(.prompt(1), frames: [("a", frame(370)), ("b", frame(370))])
        #expect(result.section == .prompt("b"))
        #expect(!result.isApproximate)
    }

    @Test func memoryReportsUncertainRepeatedMatchesForLocationFiltering() {
        var memory = ModernPromptMemory()
        let context = ModernConversationContext(processID: 1, windowID: "w", regionID: "r",
                                                title: "Chat A", conversationID: nil)
        let first = memory.observe([.init(text: "Again"), .init(text: "Again")], in: context)
        #expect(first.confidentIDs.count == 2)
        let repeated = memory.observe([.init(text: "Again")], in: context)
        #expect(repeated.confidentIDs.isEmpty)
        let result = locate(.prompt(0), ids: repeated.observedIDs, confident: repeated.confidentIDs,
                            ordered: memory.orderedIDs, groups: memory.groups)
        #expect(result.section == .unknown)
    }
}
