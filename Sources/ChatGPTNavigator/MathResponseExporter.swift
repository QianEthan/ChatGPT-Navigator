import AppKit
import WebKit
import PDFKit

/// Local conversion: Word uses editable Office equations, PDF uses native MathML.
@MainActor
enum MathResponseExporter {
    enum Failure: LocalizedError {
        case conversion(String)
        var errorDescription: String? {
            if case .conversion(let message) = self { return message }
            return nil
        }
    }
    static func markdown(_ items: [ResponseExportItem]) -> String {
        "# ChatGPT Responses\n\n" + items.enumerated().map { index, item in
            "## \(index + 1). Prompt\n\n\(item.prompt)\n\n### Response\n\n\(item.response)"
        }.joined(separator: "\n\n---\n\n") + "\n"
    }
    static func write(items: [ResponseExportItem], to destination: URL, format: ResponseExportFormat) async throws {
        let normalizedItems = try items.map { item in
            ResponseExportItem(prompt: try LatexSourceNormalizer.normalize(item.prompt),
                               response: try LatexSourceNormalizer.normalize(item.response))
        }
        let source = markdown(normalizedItems)
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }
        let result = scratch.appendingPathComponent("responses.\(format.filenameExtension)")
        if format == .markdown {
            try source.write(to: result, atomically: true, encoding: .utf8)
        } else {
            let tool = Bundle.main.resourceURL!.appendingPathComponent("Tools/pandoc")
            // Tests and source builds can use the packaged source dependency.
            let sourceTool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AppResources/Tools/pandoc")
            let executable = manager.isExecutableFile(atPath: tool.path) ? tool : sourceTool
            guard manager.isExecutableFile(atPath: executable.path) else { throw Failure.conversion("The bundled document converter is missing. Reinstall Navigator.") }
            let input = scratch.appendingPathComponent("input.md")
            try source.write(to: input, atomically: true, encoding: .utf8)
            let html = scratch.appendingPathComponent("response.html")
            let log = scratch.appendingPathComponent("conversion.log")
            manager.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = [input.path, "--from=markdown+tex_math_dollars+tex_math_single_backslash-raw_html-raw_tex", "--standalone", "--fail-if-warnings", "--metadata=pagetitle:ChatGPT Responses", "--output", format == .word ? result.path : html.path]
            if format == .pdf { process.arguments! += ["--mathml"] }
            process.standardError = handle
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Failure.conversion("Document conversion failed: " + ((try? String(contentsOf: log, encoding: .utf8)) ?? "unknown error"))
            }
            try Task.checkCancellation()
            if format == .pdf {
                let renderer = MathPDFRenderer()
                try await renderer.write(html: try String(contentsOf: html, encoding: .utf8), to: result)
            }
        }
        try Task.checkCancellation()
        // Replace only after the full document has been successfully produced.
        let data = try Data(contentsOf: result)
        try data.write(to: destination, options: .atomic)
    }
}

@MainActor
private final class MathPDFRenderer: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var completion: CheckedContinuation<Void, Error>?
    func write(html: String, to destination: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 672, height: 900), configuration: configuration)
        view.navigationDelegate = self
        web = view
        defer { web = nil }
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.completion?.resume(throwing: MathResponseExporter.Failure.conversion("PDF rendering timed out."))
                self?.completion = nil
            }
            view.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\"><style>body{font:12pt Georgia;color:black;margin:0;max-width:none}pre{white-space:pre-wrap;overflow-wrap:anywhere}img{max-width:100%}math{font-family:'STIX Two Math','Cambria Math',serif}table{border-collapse:collapse}td,th{padding:5px;border:1px solid #ccc}h1,h2,h3{break-after:avoid}math[display=block]{break-inside:avoid}</style>" + html, baseURL: nil)
        }
        try Task.checkCancellation()
        let heightValue = try await view.evaluateJavaScript("document.documentElement.scrollHeight")
        let height = (heightValue as? NSNumber)?.doubleValue ?? 900
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 672, height: height)
        let data = try await view.pdf(configuration: config)
        guard let document = PDFDocument(data: data), let page = document.page(at: 0),
              let source = page.pageRef else { throw MathResponseExporter.Failure.conversion("PDF rendering failed.") }
        let rectangles = try await view.evaluateJavaScript("""
        (()=>{let boxes=[];let w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);while(w.nextNode()){let r=document.createRange();r.selectNodeContents(w.currentNode);for(let b of r.getClientRects())if(b.height>0)boxes.push([b.top,b.bottom]);}for(let m of document.querySelectorAll('math')){let b=m.getBoundingClientRect();boxes.push([b.top,b.bottom]);}return boxes;})()
        """) as? [[Double]] ?? []
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw MathResponseExporter.Failure.conversion("PDF could not be saved.")
        }
        let scale = 504.0 / 672.0
        let capacity = 684.0 / scale
        var top = 0.0
        while top < height {
            try Task.checkCancellation()
            var bottom = min(height, top + capacity)
            // Move page breaks above text lines or equations that cross them.
            for _ in 0..<100 {
                let crossing = rectangles.filter { $0.count == 2 && $0[0] < bottom && $0[1] > bottom && $0[0] > top + 1 }
                guard let earlier = crossing.map({ $0[0] }).min() else { break }
                bottom = earlier
            }
            if bottom <= top + 1 { bottom = min(height, top + capacity) }
            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(to: CGRect(x: 54, y: 738 - (bottom - top) * scale, width: 504, height: (bottom - top) * scale))
            context.translateBy(x: 54, y: 738 + top * scale - height * scale)
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(source)
            context.restoreGState()
            context.endPDFPage()
            top = bottom
        }
        context.closePDF()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume(); completion = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error); completion = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error); completion = nil
    }
}
