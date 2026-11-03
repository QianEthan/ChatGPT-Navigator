import Testing
@testable import ChatGPTNavigator

struct NativeCopyFooterTests {
    @Test func excludesCodeAndUserCopyControls() throws {
        let nodes = [
            ModernConversationNode(role: "AXHeading", text: "ChatGPT said:", depth: 4),
            ModernConversationNode(role: "AXStaticText", text: "Answer", depth: 5),
            ModernConversationNode(role: "AXButton", text: "Copy", depth: 7),
            ModernConversationNode(role: "AXButton", text: "Copy code", depth: 6),
            ModernConversationNode(role: "AXButton", text: " Copy ", depth: 4),
            ModernConversationNode(role: "AXHeading", text: "You said:", depth: 4),
            ModernConversationNode(role: "AXButton", text: "Copy message", depth: 5)]
        #expect(ModernResponseCapturePolicy.footerButtons(in: nodes, range: 0..<5) == [4])
    }
    @Test func mathOnlyBodyDoesNotRequireTextEndpoints() {
        let nodes = [ModernConversationNode(role: "AXHeading", text: "ChatGPT said:", depth: 4),
                     ModernConversationNode(role: "AXGroup", text: "", depth: 4, subrole: "AXDocumentMath"),
                     ModernConversationNode(role: "AXButton", text: "Copy", depth: 4)]
        #expect(ModernResponseCapturePolicy.footerButtons(in: nodes, range: 0..<3) == [2])
    }
}
