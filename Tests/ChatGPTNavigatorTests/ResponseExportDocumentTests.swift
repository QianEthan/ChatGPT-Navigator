import Testing
import Foundation
@testable import ChatGPTNavigator

struct ResponseExportDocumentTests {
    @Test func createsReadableMarkdownForOneResponse() {
        let document = ResponseExportDocument.markdown(items: [
            ResponseExportItem(
                prompt: "Explain the result.",
                response: "The result is **42**."
            ),
        ])

        #expect(document.contains("# ChatGPT Responses"))
        #expect(document.contains("## 1. Prompt\n\nExplain the result."))
        #expect(document.contains("### Response\n\nThe result is **42**."))
        #expect(document.hasSuffix("\n"))
    }

    @Test func numbersMultipleSelectionsInTheirExportOrder() {
        let document = ResponseExportDocument.markdown(items: [
            ResponseExportItem(prompt: "First", response: "One"),
            ResponseExportItem(prompt: "Second", response: "Two"),
        ])

        #expect(document.contains("## 1. Prompt\n\nFirst"))
        #expect(document.contains("## 2. Prompt\n\nSecond"))
        #expect(document.contains("\n\n---\n\n"))
    }

    @Test func convertsCommonLatexIntoReadableMath() {
        let source = """
        * Matrix A: 3\\times4
        * Ratio: \\frac{1}{2}, angle \\theta, and x \\leq 5
        """

        let readable = ReadableMathText.plain(source)

        #expect(readable.contains("• Matrix A: 3 × 4"))
        #expect(readable.contains("Ratio: (1)/(2), angle θ, and x ≤ 5"))
        #expect(!readable.contains("\\times"))
    }

    @Test func convertsLatexMatricesIntoRows() {
        let readable = ReadableMathText.convert(
            #"\begin{bmatrix}1 & 2 \\ 3 & 4\end{bmatrix}"#
        )

        #expect(readable == "[ 1 2 ]\n[ 3 4 ]")
    }

    @Test func writesWordAndPDFDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ResponseExportTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let item = ResponseExportItem(
            prompt: "What are the dimensions?",
            response: "Matrix A is 3\\times4."
        )
        let wordURL = directory.appendingPathComponent("response.docx")
        let pdfURL = directory.appendingPathComponent("response.pdf")

        try ResponseExportDocument.write(items: [item], to: wordURL, format: .word)
        try ResponseExportDocument.write(items: [item], to: pdfURL, format: .pdf)

        #expect(try Data(contentsOf: wordURL).prefix(2) == Data([0x50, 0x4b]))
        #expect(String(decoding: try Data(contentsOf: pdfURL).prefix(4), as: UTF8.self) == "%PDF")
    }
}
