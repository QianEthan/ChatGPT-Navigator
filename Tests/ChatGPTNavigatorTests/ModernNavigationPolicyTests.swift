import Testing
import Foundation
@testable import ChatGPTNavigator

struct ModernNavigationPolicyTests {
    @Test func findAcceptsPartiallyVisibleLongPromptButRejectsOffscreenMatch() {
        let viewport = CGRect(x: 0, y: 100, width: 500, height: 500)
        #expect(ModernNavigationPolicy.isVisible(frame: CGRect(x: 10, y: 50, width: 400, height: 200), viewport: viewport))
        #expect(!ModernNavigationPolicy.isVisible(frame: CGRect(x: 10, y: -200, width: 400, height: 200), viewport: viewport))
        #expect(!ModernNavigationPolicy.isVisible(frame: CGRect(x: 600, y: 150, width: 100, height: 200), viewport: viewport))
    }
    @Test func findQueryIsOneLineAndPreservesLiteralBackslashes() {
        #expect(ModernNavigationPolicy.query(for: "Short\n\\frac{x}{y}   is the longer line\nEnd") == #"\frac{x}{y} is the longer line"#)
        #expect(ModernNavigationPolicy.query(for: String(repeating: "x", count: 180))?.count == 100)
        #expect(ModernNavigationPolicy.query(for: " \n\t") == nil)
    }

    @Test func recognizesExplicitFindControls() {
        #expect(ModernNavigationPolicy.isFindField(role: "AXTextField", subrole: "", labels: ["Find in conversation"]))
        #expect(ModernNavigationPolicy.isFindField(role: "AXTextField", subrole: "AXSearchField", labels: ["Find…"]))
        #expect(ModernNavigationPolicy.isFindField(role: "AXTextField", subrole: "", labels: ["find-input"]))
        #expect(ModernNavigationPolicy.isFindField(role: "AXTextField", subrole: "", labels: ["search this conversation"]))
    }

    @Test func composerAndGenericGlobalSearchNeverQualifyAsFind() {
        #expect(!ModernNavigationPolicy.isFindField(role: "AXTextArea", subrole: "", labels: ["Find in conversation"]))
        #expect(!ModernNavigationPolicy.isFindField(role: "AXTextField", subrole: "AXSearchField", labels: ["Search"]))
        #expect(!ModernNavigationPolicy.isFindField(role: "AXTextField", subrole: "", labels: ["Message ChatGPT"]))
        #expect(!ModernNavigationPolicy.isFindField(role: "AXTextField", subrole: "", labels: ["Search chats"]))
        #expect(!ModernNavigationPolicy.isFindField(role: "AXTextField", subrole: "", labels: ["Rename chat"]))
    }

    @Test func matchingStillRequiresTheWholePrompt() {
        let entries = [ModernPromptObservation(text: "First line\nSpecific second line"),
                       ModernPromptObservation(text: "First line\nDifferent second line")]
        #expect(ModernNavigationPolicy.matchingIndices(text: "First line", entries: entries).isEmpty)
        #expect(ModernNavigationPolicy.matchingIndices(text: "First line Specific second line", entries: entries) == [0])
    }

    @Test func repeatedPromptsAreAcceptedRegardlessOfNativeIdentity() {
        let entries = [ModernPromptObservation(text: "Again", nativeID: "A"),
                       ModernPromptObservation(text: "Again", nativeID: "B"),
                       ModernPromptObservation(text: "Again")]
        #expect(ModernNavigationPolicy.matchingIndices(text: "Again", entries: entries) == [0, 1, 2])
    }

    @Test func duplicateIDsDoNotBlockFindButEditedTextDoesNotMatch() {
        let entries = [ModernPromptObservation(text: "Again", nativeID: "A"),
                       ModernPromptObservation(text: "Again", nativeID: "A")]
        #expect(ModernNavigationPolicy.matchingIndices(text: "Again", entries: entries) == [0, 1])
        #expect(ModernNavigationPolicy.matchingIndices(text: "Before edit", entries: entries).isEmpty)
        #expect(ModernNavigationPolicy.matchingIndices(text: " \n", entries: entries).isEmpty)
    }
}
