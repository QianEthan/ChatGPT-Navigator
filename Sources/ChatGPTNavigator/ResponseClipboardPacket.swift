import AppKit
import Foundation

struct ResponseClipboardPacket: Codable {
    let schemaVersion: Int
    let capturedAt: String
    let prompt: String
    let plainText: String?
    let selectionTextBeforeCopy: String?
    let items: [[String: Data]]
    var selectionMethod: String? = nil
    var selectionTrace: [String]? = nil
    var formats: [String] { Array(Set(items.flatMap { $0.keys })).sorted() }

    @MainActor
    static func read(from pasteboard: NSPasteboard, prompt: String, selection: String?) -> Self {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
        return Self(schemaVersion: 1, capturedAt: ISO8601DateFormatter().string(from: Date()),
                    prompt: prompt, plainText: pasteboard.string(forType: .string),
                    selectionTextBeforeCopy: selection, items: items)
    }
}

enum ResponseSelectionGeometry {
    struct Plan { let start: CGPoint; let end: CGPoint }
    static func plan(first: CGRect, last: CGRect, content: CGRect, viewport: CGRect) -> Plan? {
        let rectangles = [first, last, content, viewport]
        guard rectangles.allSatisfy({ !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 && [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }),
              viewport.insetBy(dx: -0.5, dy: -0.5).contains(content) else { return nil }
        let start = CGPoint(x: first.minX + 0.1, y: first.midY)
        let end = CGPoint(x: last.maxX + 0.5, y: last.midY)
        guard viewport.contains(start), viewport.contains(end) else { return nil }
        return Plan(start: start, end: end)
    }
}
