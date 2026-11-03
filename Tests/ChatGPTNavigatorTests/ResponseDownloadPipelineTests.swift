import Foundation
import Testing
@testable import ChatGPTNavigator

@MainActor
struct ResponseDownloadPipelineTests {
    @Test func eachDownloadCopiesFreshContentBeforeWriting() async throws {
        var events: [String] = []
        for reply in ["First reply", "Second reply"] {
            try await ResponseDownloadPipeline.run(copy: {
                events.append("copy " + reply); return reply
            }, write: { text in events.append("write " + text) })
        }
        #expect(events == ["copy First reply", "write First reply", "copy Second reply", "write Second reply"])
    }
    @Test func failedCopyNeverStartsConversion() async {
        var writes = 0
        do {
            try await ResponseDownloadPipeline.run(copy: { nil }, write: { _ in writes += 1 })
            Issue.record("Missing copy must fail")
        } catch { #expect(error is ResponseDownloadPipeline.Failure) }
        #expect(writes == 0)
    }
    @Test func cancellationAfterCopyDoesNotWrite() async {
        var writes = 0
        let task = Task { @MainActor in
            try await ResponseDownloadPipeline.run(copy: {
                withUnsafeCurrentTask { $0?.cancel() }
                return "Copied reply"
            }, write: { _ in writes += 1 })
        }
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(writes == 0)
    }
}
