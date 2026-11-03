import AppKit
import CoreText
import Foundation

struct ResponseExportItem: Equatable {
    let prompt: String
    let response: String
}

enum ResponseExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case word
    case pdf

    var id: Self { self }

    var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .word: return "Word"
        case .pdf: return "PDF"
        }
    }

    var filenameExtension: String {
        switch self {
        case .markdown: return "md"
        case .word: return "docx"
        case .pdf: return "pdf"
        }
    }
}

enum ResponseExportDocument {
    static func defaultFilename(for format: ResponseExportFormat) -> String {
        "ChatGPT Responses.\(format.filenameExtension)"
    }

    static func write(
        items: [ResponseExportItem],
        to destination: URL,
        format: ResponseExportFormat
    ) throws {
        switch format {
        case .markdown:
            try markdown(items: items)
                .write(to: destination, atomically: true, encoding: .utf8)
        case .word:
            try writeWordDocument(items: items, to: destination)
        case .pdf:
            try writePDF(items: items, to: destination)
        }
    }

    static func markdown(items: [ResponseExportItem]) -> String {
        var sections = ["# ChatGPT Responses"]

        for (index, item) in items.enumerated() {
            sections.append(
                """
                ## \(index + 1). Prompt

                \(ReadableMathText.convert(item.prompt))

                ### Response

                \(ReadableMathText.convert(item.response))
                """
            )
        }

        return sections.joined(separator: "\n\n---\n\n") + "\n"
    }

    private static func writeWordDocument(
        items: [ResponseExportItem],
        to destination: URL
    ) throws {
        let manager = FileManager.default
        let packageRoot = manager.temporaryDirectory.appendingPathComponent(
            "ChatGPT-Navigator-Word-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? manager.removeItem(at: packageRoot) }

        let relationships = packageRoot.appendingPathComponent("_rels", isDirectory: true)
        let word = packageRoot.appendingPathComponent("word", isDirectory: true)
        try manager.createDirectory(at: relationships, withIntermediateDirectories: true)
        try manager.createDirectory(at: word, withIntermediateDirectories: true)

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        try contentTypes.write(
            to: packageRoot.appendingPathComponent("[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )
        try rootRelationships.write(
            to: relationships.appendingPathComponent(".rels"),
            atomically: true,
            encoding: .utf8
        )
        try wordDocumentXML(items: items).write(
            to: word.appendingPathComponent("document.xml"),
            atomically: true,
            encoding: .utf8
        )

        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = packageRoot
        zip.arguments = [
            "-q", "-r", destination.path,
            "[Content_Types].xml", "_rels", "word",
        ]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw ResponseExportError.wordCreationFailed
        }
    }

    private static func wordDocumentXML(items: [ResponseExportItem]) -> String {
        var body = wordParagraph("ChatGPT Responses", bold: true, size: 34)

        for (index, item) in items.enumerated() {
            body += wordParagraph("\(index + 1). Prompt", bold: true, size: 28)
            body += wordBodyParagraphs(ReadableMathText.plain(item.prompt))
            body += wordParagraph("Response", bold: true, size: 25)
            body += wordBodyParagraphs(ReadableMathText.plain(item.response))
            if index < items.count - 1 {
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            \(body)
            <w:sectPr>
              <w:pgSz w:w="12240" w:h="15840"/>
              <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """
    }

    private static func wordBodyParagraphs(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { wordParagraph($0, bold: false, size: 22) }
            .joined()
    }

    private static func wordParagraph(
        _ text: String,
        bold: Bool,
        size: Int
    ) -> String {
        let boldTag = bold ? "<w:b/>" : ""
        return """
        <w:p>
          <w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr>
          <w:r><w:rPr>\(boldTag)<w:sz w:val="\(size)"/></w:rPr><w:t xml:space="preserve">\(xmlEscaped(text))</w:t></w:r>
        </w:p>
        """
    }

    private static func writePDF(
        items: [ResponseExportItem],
        to destination: URL
    ) throws {
        let content = pdfAttributedString(items: items)
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(
                  consumer: consumer,
                  mediaBox: &mediaBox,
                  nil
              ) else {
            throw ResponseExportError.pdfCreationFailed
        }

        let textRect = CGRect(x: 54, y: 54, width: 504, height: 684)
        var location = 0
        while location < content.length {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 else { break }
            location += visible.length
        }
        context.closePDF()
    }

    private static func pdfAttributedString(
        items: [ResponseExportItem]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8

        func append(_ text: String, size: CGFloat, weight: NSFont.Weight) {
            result.append(
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: size, weight: weight),
                        .foregroundColor: NSColor.black,
                        .paragraphStyle: paragraph,
                    ]
                )
            )
        }

        append("ChatGPT Responses\n\n", size: 22, weight: .bold)
        for (index, item) in items.enumerated() {
            append("\(index + 1). Prompt\n", size: 15, weight: .semibold)
            append("\(ReadableMathText.plain(item.prompt))\n\n", size: 11, weight: .regular)
            append("Response\n", size: 13, weight: .semibold)
            append("\(ReadableMathText.plain(item.response))\n", size: 11, weight: .regular)
            if index < items.count - 1 {
                append("\n--------------------------------\n\n", size: 10, weight: .regular)
            }
        }
        return result
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum ReadableMathText {
    static func plain(_ input: String) -> String {
        var output = convert(input)
        output = replacingRegex(
            #"(?m)^\s*[-*+]\s+"#,
            in: output,
            with: "• "
        )
        output = replacingRegex(#"(?m)^#{1,6}\s+"#, in: output, with: "")
        output = output.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "```", with: "")
        return output
    }

    static func convert(_ input: String) -> String {
        var output = convertMatrices(in: input)

        for _ in 0..<4 {
            output = replacingRegex(
                #"\\frac\{([^{}]+)\}\{([^{}]+)\}"#,
                in: output,
                with: "($1)/($2)"
            )
            output = replacingRegex(
                #"\\sqrt\{([^{}]+)\}"#,
                in: output,
                with: "√($1)"
            )
            output = replacingRegex(
                #"\\text\{([^{}]+)\}"#,
                in: output,
                with: "$1"
            )
        }

        let replacements: [(String, String)] = [
            ("\\times", " × "), ("\\cdot", " · "),
            ("\\div", " ÷ "), ("\\pm", " ± "),
            ("\\leq", " ≤ "), ("\\le", " ≤ "),
            ("\\geq", " ≥ "), ("\\ge", " ≥ "),
            ("\\neq", " ≠ "), ("\\ne", " ≠ "),
            ("\\approx", " ≈ "), ("\\equiv", " ≡ "),
            ("\\rightarrow", " → "), ("\\leftarrow", " ← "),
            ("\\infty", "∞"), ("\\sum", "∑"),
            ("\\prod", "∏"), ("\\int", "∫"),
            ("\\alpha", "α"), ("\\beta", "β"),
            ("\\gamma", "γ"), ("\\delta", "δ"),
            ("\\theta", "θ"), ("\\lambda", "λ"),
            ("\\mu", "μ"), ("\\pi", "π"),
            ("\\sigma", "σ"), ("\\phi", "φ"),
            ("\\omega", "ω"),
        ]
        for (command, readable) in replacements {
            output = output.replacingOccurrences(of: command, with: readable)
        }

        output = output.replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")
            .replacingOccurrences(of: "\\(", with: "")
            .replacingOccurrences(of: "\\)", with: "")
            .replacingOccurrences(of: "\\[", with: "")
            .replacingOccurrences(of: "\\]", with: "")
        output = replacingRegex(#"[ \t]{2,}"#, in: output, with: " ")
        return output
    }

    private static func convertMatrices(in input: String) -> String {
        var output = input
        for environment in ["bmatrix", "pmatrix", "matrix"] {
            let pattern = #"(?s)\\begin\{"# + environment +
                #"\}(.*?)\\end\{"# + environment + #"\}"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let matches = regex.matches(
                in: output,
                range: NSRange(output.startIndex..., in: output)
            )
            for match in matches.reversed() {
                guard let fullRange = Range(match.range(at: 0), in: output),
                      let bodyRange = Range(match.range(at: 1), in: output) else {
                    continue
                }
                let body = String(output[bodyRange])
                let rows = body.components(separatedBy: "\\\\").map { row in
                    row.components(separatedBy: "&")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .joined(separator: "  ")
                }
                let open = environment == "pmatrix" ? "(" : "["
                let close = environment == "pmatrix" ? ")" : "]"
                let readable = rows.map { "\(open) \($0) \(close)" }
                    .joined(separator: "\n")
                output.replaceSubrange(fullRange, with: readable)
            }
        }
        return output
    }

    private static func replacingRegex(
        _ pattern: String,
        in input: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        return regex.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: replacement
        )
    }
}

private enum ResponseExportError: LocalizedError {
    case wordCreationFailed
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .wordCreationFailed:
            return "The Word document could not be packaged."
        case .pdfCreationFailed:
            return "The PDF document could not be created."
        }
    }
}
