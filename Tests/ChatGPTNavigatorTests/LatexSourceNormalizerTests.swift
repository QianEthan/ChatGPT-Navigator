import Foundation
import Testing
@testable import ChatGPTNavigator

struct LatexSourceNormalizerTests {
    @Test func unescapesOnlyMathAndPreservesMatrixSeparators() throws {
        let input = #"Path C:\\Files. \\[ \\begin{bmatrix}1&2\\\\3&4\\end{bmatrix} \\]"#
        #expect(try LatexSourceNormalizer.normalize(input) == #"Path C:\\Files. \[ \begin{bmatrix}1&2\\3&4\end{bmatrix} \]"#)
        #expect(try LatexSourceNormalizer.normalize(#"\[\frac{1}{2}\]"#) == #"\[\frac{1}{2}\]"#)
    }
    @Test func keepsCodeExamplesAndProseBrackets() throws {
        let input = #"Use [brackets] and `\\[\\frac{1}{2}\\]` as literal code."#
        #expect(try LatexSourceNormalizer.normalize(input) == input)
    }
    @MainActor
    @Test func exportsSyntheticPassageAsSevenEditableEquations() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "SyntheticMath", withExtension: "md", subdirectory: "Fixtures"))
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
        defer { try? FileManager.default.removeItem(at: path) }
        try await MathResponseExporter.write(items: [ResponseExportItem(prompt: "Synthetic equation example", response: source)], to: path, format: .word)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", path.path, "word/document.xml"]
        let pipe = Pipe(); p.standardOutput = pipe; try p.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        #expect(xml.components(separatedBy: "<m:oMath>").count - 1 == 7)
        #expect(xml.components(separatedBy: "<m:m>").count - 1 == 3)
        #expect(xml.contains("<m:borderBox>"))
        #expect(xml.contains("Synthetic equation example:"))
        #expect(!xml.contains(#"\\begin"#))
    }
}
