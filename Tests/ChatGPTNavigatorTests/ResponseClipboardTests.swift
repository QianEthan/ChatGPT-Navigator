import AppKit
import Testing
@testable import ChatGPTNavigator

struct ResponseClipboardTests {
    @Test func selectionRequiresWholeVisibleResponseAndValidEndpoints() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let first = CGRect(x: 20, y: 20, width: 8, height: 18)
        let last = CGRect(x: 300, y: 200, width: 4, height: 18)
        let content = CGRect(x: 20, y: 20, width: 700, height: 198)
        let plan = ResponseSelectionGeometry.plan(first: first, last: last, content: content, viewport: viewport)
        #expect(plan?.start == CGPoint(x: 20.1, y: 29))
        #expect(plan?.end == CGPoint(x: 304.5, y: 209))
        #expect(ResponseSelectionGeometry.plan(first: first, last: last, content: CGRect(x: 20, y: 20, width: 700, height: 900), viewport: viewport) == nil)
        #expect(ResponseSelectionGeometry.plan(first: .null, last: last, content: content, viewport: viewport) == nil)
    }
    @Test func preservesRichPayloadBytesThroughSavedPacket() throws {
        let html = Data("<p>Answer <math><mfrac><mn>1</mn><mn>2</mn></mfrac></math></p>".utf8)
        let rtf = Data(#"{\rtf1 Answer}"#.utf8)
        let items = [["public.html": html, "public.rtf": rtf, "public.utf8-plain-text": Data("Answer".utf8)]]
        let packet = ResponseClipboardPacket(schemaVersion: 1, capturedAt: "2026-10-31T00:00:00Z", prompt: "Question", plainText: "Answer", selectionTextBeforeCopy: "Answer", items: items)
        let restored = try JSONDecoder().decode(ResponseClipboardPacket.self, from: JSONEncoder().encode(packet))
        #expect(restored.items[0]["public.html"] == html)
        #expect(restored.items[0]["public.rtf"] == rtf)
        #expect(restored.formats == ["public.html", "public.rtf", "public.utf8-plain-text"])
    }
}
