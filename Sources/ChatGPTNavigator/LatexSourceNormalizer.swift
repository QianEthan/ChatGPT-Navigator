import Foundation

/// Removes one escape layer only inside paired math zones. Prose and code stay intact.
enum LatexSourceNormalizer {
    static func normalize(_ source: String) throws -> String {
        let math = try NSRegularExpression(pattern: #"(?s)(?<!\\)(\\{1,2})(\[|\()(.*?)\1(\]|\))"#)
        let code = try NSRegularExpression(pattern: #"(?s)```.*?(?:```|\z)|~~~.*?(?:~~~|\z)|`[^`\n]*`"#)
        let whole = NSRange(source.startIndex..., in: source)
        let protected = code.matches(in: source, range: whole).map(\.range)
        var result = source
        for match in math.matches(in: source, range: whole).reversed() {
            if protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            guard let full = Range(match.range, in: result),
                  let prefix = Range(match.range(at: 1), in: result),
                  let opening = Range(match.range(at: 2), in: result),
                  let body = Range(match.range(at: 3), in: result),
                  let closing = Range(match.range(at: 4), in: result) else { continue }
            let open = String(result[opening]), close = String(result[closing])
            guard (open == "[" && close == "]") || (open == "(" && close == ")") else {
                throw MathResponseExporter.Failure.conversion("Math delimiters do not match. Save the capture for inspection.")
            }
            if result[prefix].count == 2 {
                let expression = result[body].replacingOccurrences(of: "\\\\", with: "\\")
                result.replaceSubrange(full, with: "\\" + open + expression + "\\" + close)
            }
        }
        return result
    }
}
