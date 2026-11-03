import Foundation
import Testing
@testable import ChatGPTNavigator

@MainActor
struct BatchDownloadTests {
    @Test func capturesInOrderAndWritesExactlyOnce() async throws {
        var calls: [Int] = []
        var writes = 0
        try await ResponseDownloadPipeline.runBatch(prompts: ["First", "Second", "Third"], copy: { index in
            calls.append(index); return ["Apple", "Banana", "Cherry"][index]
        }, write: { items in
            writes += 1
            #expect(items.map(\.prompt) == ["First", "Second", "Third"])
            #expect(items.map(\.response) == ["Apple", "Banana", "Cherry"])
            #expect(calls == [0, 1, 2])
        })
        #expect(writes == 1)
    }
    @Test func secondReplyFailureDoesNotSavePartialDocumentOrCopyThird() async {
        var calls: [Int] = []; var writes = 0
        do {
            try await ResponseDownloadPipeline.runBatch(prompts: ["A", "B", "C"], copy: { index in
                calls.append(index); return index == 1 ? nil : "Reply"
            }, write: { _ in writes += 1 })
            Issue.record("Expected copy failure")
        } catch { #expect(error.localizedDescription.contains("Reply 2")) }
        #expect(calls == [0, 1]); #expect(writes == 0)
    }
    @Test func cancellationBetweenRepliesDoesNotWrite() async {
        var calls: [Int] = []; var writes = 0
        let task = Task { @MainActor in
            try await ResponseDownloadPipeline.runBatch(prompts: ["A", "B"], copy: { index in
                calls.append(index); withUnsafeCurrentTask { $0?.cancel() }; return "Reply"
            }, write: { _ in writes += 1 })
        }
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(calls == [0]); #expect(writes == 0)
    }
    @Test func singleSelectionUsesSameBatchPath() async throws {
        try await ResponseDownloadPipeline.runBatch(prompts: ["Only"], copy: { index in
            #expect(index == 0); return "One reply"
        }, write: { items in #expect(items == [ResponseExportItem(prompt: "Only", response: "One reply")]) })
    }
    @Test func multipleMathRepliesBecomeOneWordDocument() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
        defer { try? FileManager.default.removeItem(at: path) }
        let replies = [#"First answer: \(\frac{1}{2}\)."#, #"Second answer: \\[\\sqrt{x}\\]."#]
        try await ResponseDownloadPipeline.runBatch(prompts: ["First prompt", "Second prompt"], copy: { replies[$0] }, write: { items in
            try await MathResponseExporter.write(items: items, to: path, format: .word)
        })
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", path.path, "word/document.xml"]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        #expect(xml.components(separatedBy: "<m:oMath>").count - 1 == 2)
        #expect(xml.contains("<m:f>")); #expect(xml.contains("<m:rad>"))
        let first = try #require(xml.range(of: "First answer:"))
        let second = try #require(xml.range(of: "Second answer:"))
        #expect(first.lowerBound < second.lowerBound)
    }
}
