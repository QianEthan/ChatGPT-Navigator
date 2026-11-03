import Testing
import Foundation
@testable import ChatGPTNavigator

struct ModernResponseCapturePolicyTests {
    func node(_ role: String, _ label: String, _ depth: Int) -> ModernConversationNode {
        // Run the same label collection path as the real Accessibility walker.
        ModernConversationNode(role: role, text: ModernResponseCapturePolicy.nodeText(role: role) { label }, depth: depth)
    }
    @Test func physicalClickRequiresSmallFullyVisibleButton() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(ModernResponseCapturePolicy.clickPoint(button: CGRect(x: 200, y: 200, width: 30, height: 30), window: window) == CGPoint(x: 215, y: 215))
        #expect(ModernResponseCapturePolicy.clickPoint(button: CGRect(x: 200, y: 80, width: 30, height: 30), window: window) == nil)
        #expect(ModernResponseCapturePolicy.clickPoint(button: CGRect(x: 200, y: 200, width: 500, height: 30), window: window) == nil)
        #expect(ModernResponseCapturePolicy.clickPoint(button: .zero, window: window) == nil)
        #expect(ModernResponseCapturePolicy.clickPoint(button: .null, window: window) == nil)
    }
    @Test func walkerRetainsCopyLabelAndSelectsWholeResponseInsteadOfCodeOrNextTurn() throws {
        let nodes = [
            node("AXHeading", "You said:", 2),
            node("AXStaticText", "Explain", 3),
            node("AXButton", "Copy", 3), // user copy must be excluded
            node("AXHeading", "ChatGPT said:", 2),
            node("AXStaticText", "Answer with code and math", 3),
            node("AXButton", "Copy code", 4),
            node("AXButton", "Copy response", 3),
            node("AXHeading", "You said:", 2),
            node("AXStaticText", "Next question", 3),
            node("AXButton", "Copy", 3),
        ]
        let range = try #require(ModernResponseCapturePolicy.responseRange(in: nodes, following: 0))
        #expect(ModernResponseCapturePolicy.copyButtons(in: nodes, range: range) == [6])
        #expect(nodes[6].text == "Copy response")
    }
    @Test func refusesToSkipToAnotherTurnsAnswer() {
        let nodes = [node("AXHeading", "You said:", 1), node("AXHeading", "You said:", 1), node("AXHeading", "ChatGPT said:", 1), node("AXButton", "Copy", 2)]
        #expect(ModernResponseCapturePolicy.responseRange(in: nodes, following: 0) == nil)
    }
    @Test func nestedSpeakerQuoteDoesNotEndResponse() throws {
        let nodes = [node("AXHeading", "You said:", 1), node("AXHeading", "ChatGPT said:", 1), node("AXHeading", "You said:", 3), node("AXButton", " Copy Message ", 2)]
        let range = try #require(ModernResponseCapturePolicy.responseRange(in: nodes, following: 0))
        #expect(ModernResponseCapturePolicy.copyButtons(in: nodes, range: range) == [3])
    }
    @Test func supportsClassicCustomCopyActionWithoutChoosingCodeCopy() {
        #expect(ModernResponseCapturePolicy.copyAction("Name: Copy\nDescription: Copy the response"))
        #expect(!ModernResponseCapturePolicy.copyAction("Name: Copy code"))
        #expect(!ModernResponseCapturePolicy.copyAction("AXPress"))
    }
}
