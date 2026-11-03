import Foundation
import Testing
@testable import ChatGPTNavigator

struct ModernResponseTextTests {
    struct FixtureNode: Decodable {
        let role: String; let text: String; let depth: Int; let subrole: String
    }
    @Test func extractsSyntheticAppleBananaCherrySnapshotWithoutUIOrClipboard() throws {
        let url = try #require(Bundle.module.url(forResource: "SyntheticTextResponses", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([FixtureNode].self, from: Data(contentsOf: url))
        let nodes = fixture.map { ModernConversationNode(role: $0.role, text: $0.text, depth: $0.depth, subrole: $0.subrole) }
        let prompts = ModernConversationParser.userPrompts(in: nodes)
        #expect(prompts.count == 3)
        let responses = prompts.compactMap { ModernResponseText.extract(in: nodes, following: $0) }
        #expect(responses == ["Apple.", "Banana.", "Cherry."])
    }
    @MainActor
    @Test func exportsSyntheticSnapshotToMarkdownAndWord() async throws {
        let url = try #require(Bundle.module.url(forResource: "SyntheticTextResponses", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([FixtureNode].self, from: Data(contentsOf: url))
        let nodes = fixture.map { ModernConversationNode(role: $0.role, text: $0.text, depth: $0.depth, subrole: $0.subrole) }
        let prompt = try #require(ModernConversationParser.userPrompts(in: nodes).first)
        let answer = try #require(ModernResponseText.extract(in: nodes, following: prompt))
        let item = ResponseExportItem(prompt: prompt.text, response: answer)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = directory.appendingPathComponent("synthetic.md")
        try await MathResponseExporter.write(items: [item], to: markdown, format: .markdown)
        let contents = try String(contentsOf: markdown, encoding: .utf8)
        #expect(contents.contains("### Response\n\nApple."))
        #expect(!contents.contains("Copy message"))
        let word = directory.appendingPathComponent("synthetic.docx")
        try await MathResponseExporter.write(items: [item], to: word, format: .word)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", word.path, "word/document.xml"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(xml.contains("Apple."))
        #expect(!xml.contains("Banana."))
    }
    func node(_ role: String, _ text: String, _ depth: Int, _ subrole: String = "") -> ModernConversationNode {
        ModernConversationNode(role: role, text: text, depth: depth, subrole: subrole)
    }
    @Test func preservesInlineWordsParagraphsAndListsWithoutControlLabels() throws {
        let nodes = [node("AXHeading", "You said:", 4), node("AXGroup", "", 4), node("AXStaticText", "Question", 5),
            node("AXHeading", "ChatGPT said:", 4), node("AXStaticText", "ChatGPT said:", 5),
            node("AXGroup", "", 4, "AXApplicationStatus"), node("AXStaticText", "Worked for 10s", 5),
            node("AXGroup", "", 4), node("AXStaticText", "Hello ", 5), node("AXGroup", "", 5, "AXStrongStyleGroup"), node("AXStaticText", "world", 6), node("AXStaticText", ".", 5),
            node("AXList", "", 4), node("AXGroup", "", 5), node("AXListMarker", "•", 6), node("AXStaticText", "One", 6), node("AXGroup", "", 5), node("AXListMarker", "•", 6), node("AXStaticText", "Two", 6),
            node("AXGroup", "", 4), node("AXStaticText", "End.", 5),
            node("AXButton", "Copy", 4), node("AXStaticText", "Friday 7:41 PM", 4)]
        let prompt = try #require(ModernConversationParser.userPrompts(in: nodes).first)
        #expect(ModernResponseText.extract(in: nodes, following: prompt) == "Hello world.\n\n• One\n• Two\n\nEnd.")
    }
    @Test func doesNotExportStreamingOrMissingAnswer() throws {
        let nodes = [node("AXHeading", "You said:", 4), node("AXGroup", "", 4), node("AXStaticText", "Question", 5), node("AXHeading", "ChatGPT said:", 4), node("AXGroup", "", 4), node("AXStaticText", "Not finished", 5)]
        let prompt = try #require(ModernConversationParser.userPrompts(in: nodes).first)
        #expect(ModernResponseText.extract(in: nodes, following: prompt) == nil)
    }
}
