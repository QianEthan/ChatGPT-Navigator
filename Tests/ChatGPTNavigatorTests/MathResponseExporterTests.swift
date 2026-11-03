import Testing
import AppKit
import PDFKit
@testable import ChatGPTNavigator

@MainActor
struct MathResponseExporterTests {
    let item = ResponseExportItem(prompt: "Show math", response: #"A fraction \(\frac{1}{\sqrt{x^2+1}}\), and $$\begin{bmatrix}1&2\\3&4\end{bmatrix}$$"#)
    @Test func preservesOriginalMathInMarkdown() {
        #expect(MathResponseExporter.markdown([item]).contains(item.response))
    }
    @Test func rendersOfficeEquations() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
        defer { try? FileManager.default.removeItem(at: path) }
        try await MathResponseExporter.write(items: [item], to: path, format: .word)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", path.path, "word/document.xml"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("<m:f>"))
        #expect(xml.contains("<m:rad>"))
        #expect(xml.contains("<m:m>"))
        #expect(!xml.contains("\\frac"))
    }
    @Test func exportsUsersIntegralWithoutFlatteningLatex() async throws {
        let equation = #"\[ \int_1^5 x^2\,dx =\left[\frac{x^3}{3}\right]_1^5 =\frac{125-1}{3} =\boxed{\frac{124}{3}}. \]"#
        let item = ResponseExportItem(prompt: "Evaluate the integral", response: equation)
        #expect(MathResponseExporter.markdown([item]).contains(equation))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
        defer { try? FileManager.default.removeItem(at: path) }
        try await MathResponseExporter.write(items: [item], to: path, format: .word)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", path.path, "word/document.xml"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(xml.contains("<m:nary>"))
        #expect(xml.contains("<m:f>"))
        #expect(!xml.contains("\\int"))
    }
    @Test func rendersPaginatedPDF() async throws {
        _ = NSApplication.shared
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: path) }
        let long = ResponseExportItem(prompt: item.prompt, response: item.response + String(repeating: "\n\nA paragraph of explanatory text with enough content to span multiple printed pages.\n", count: 80))
        try await MathResponseExporter.write(items: [long], to: path, format: .pdf)
        let pdf = try #require(PDFDocument(url: path))
        #expect(pdf.pageCount > 1)
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).height == 792)
        #expect(pdf.string?.contains("A fraction") == true)
        #expect(pdf.string?.contains("\\frac") == false)
    }
}
