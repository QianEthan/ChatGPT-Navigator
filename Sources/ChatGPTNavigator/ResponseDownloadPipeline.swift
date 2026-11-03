import Foundation

@MainActor
enum ResponseDownloadPipeline {
    enum Failure: LocalizedError {
        case noResponse, noSelection, noResponseAt(Int)
        var errorDescription: String? {
            switch self {
            case .noResponse: return "ChatGPT did not supply a response text source."
            case .noSelection: return "Select at least one prompt."
            case .noResponseAt(let number): return "Reply \(number) could not be copied completely."
            }
        }
    }
    static func run(copy: () async -> String?, write: (String) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard let response = await copy(), !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.noResponse
        }
        try Task.checkCancellation()
        try await write(response)
        try Task.checkCancellation()
    }

    /// Capture serially and commit one combined document after all replies succeed.
    static func runBatch(prompts: [String], copy: (Int) async -> String?,
                         write: ([ResponseExportItem]) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !prompts.isEmpty else { throw Failure.noSelection }
        var items: [ResponseExportItem] = []
        for (index, prompt) in prompts.enumerated() {
            try Task.checkCancellation()
            guard let response = await copy(index), !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.noResponseAt(index + 1)
            }
            try Task.checkCancellation()
            items.append(ResponseExportItem(prompt: prompt, response: response))
        }
        try await write(items)
        try Task.checkCancellation()
    }
}
