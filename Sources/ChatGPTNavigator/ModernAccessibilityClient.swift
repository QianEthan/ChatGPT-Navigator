import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ModernAccessibilityClient {
    static let bundleIdentifier = "com.openai.codex"
    let worker: ModernAXWorker

    init(worker: ModernAXWorker = ModernAXWorker()) { self.worker = worker }

    func scan(includeLocation: Bool = false, includeIndexing: Bool = false,
              includeDiagnostics: Bool = false, includeResponses: Bool = false) async -> ConversationSnapshot? {
        await worker.scan(options: .init(location: includeLocation, indexing: includeIndexing,
                                        diagnostics: includeDiagnostics, responses: includeResponses))
    }

    func probe() async -> ModernConversationProbe? { await worker.probe() }

    private func boundedAttribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? T
    }

    @MainActor private(set) var lastCaptureFailure = ""
    @MainActor private(set) var lastSelectionTrace: [String] = []

    /// Directly reads a loaded response. No app activation, Find, clicking, or clipboard.
    @MainActor
    func captureResponse(following entry: NavigationEntry, context expected: ModernConversationContext) async -> String? {
        lastCaptureFailure = ""
        guard !Task.isCancelled, let snapshot = await scan(includeIndexing: true, includeResponses: true),
              snapshot.modernContext?.sessionKey == expected.sessionKey else {
            lastCaptureFailure = "The selected conversation is unavailable."
            return nil
        }
        let matches = snapshot.entries.filter {
            $0.fullText == entry.fullText && (entry.modernSourceID == nil || $0.modernSourceID == entry.modernSourceID)
        }
        guard matches.count == 1, let match = matches.first,
              let text = snapshot.modernResponseTexts[match.id] else {
            lastCaptureFailure = "The complete selected response is not loaded. Scroll to it in ChatGPT, then use Preview response."
            return nil
        }
        return text
    }

    @MainActor
    func copyResponseWithNativeButton(following entry: NavigationEntry, context expected: ModernConversationContext) async -> ResponseClipboardPacket? {
        lastCaptureFailure = ""
        lastSelectionTrace = ["method=native-footer-click"]
        func fail(_ text: String) -> ResponseClipboardPacket? { lastCaptureFailure = text; return nil }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first,
              app.processIdentifier == expected.processID,
              let original = CGEvent(source: nil)?.location else { return fail("Open the selected ChatGPT conversation first.") }
        app.activate(options: [])
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return nil }
        let lease = ModernInputLease()
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        var parked = original
        defer {
            if lease.isCurrent, let p = CGEvent(source: nil)?.location,
               hypot(p.x - parked.x, p.y - parked.y) <= 8 { _ = CGWarpMouseCursorPosition(original) }
            lease.release()
        }
        func current() async -> Bool {
            guard !Task.isCancelled, lease.isCurrent, ProcessInfo.processInfo.systemUptime < deadline, NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.processID else { return false }
            let value = await probe()
            return !Task.isCancelled && lease.isCurrent && ProcessInfo.processInfo.systemUptime < deadline && NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.processID && value?.context?.sessionKey == expected.sessionKey
        }
        func pointerOwned() -> Bool {
            guard !Task.isCancelled, lease.isCurrent, ProcessInfo.processInfo.systemUptime < deadline,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.processID,
                  let p = CGEvent(source: nil)?.location else { return false }
            return hypot(p.x - parked.x, p.y - parked.y) <= 8
        }
        func locate() async -> ModernCopyTarget? {
            guard await current() else { return nil }
            return await worker.copyTarget(entry: entry, expected: expected)
        }
        guard let initial = await locate() else { return fail("No unique assistant-footer Copy button was found for this prompt. Open that response and retry.") }
        guard pointerOwned() else { return fail("Copy stopped because input changed.") }
        let scrollResult = await worker.scrollToVisible(.init(element: initial.button), expected: expected)
        lastSelectionTrace.append("scroll-button=\(scrollResult)")
        var usedNextPrompt = false
        for attempt in 0..<12 {
            try? await Task.sleep(for: .milliseconds(160))
            guard await current(), pointerOwned() else { return fail("Copy stopped because the pointer, focus, or conversation changed.") }
            guard let candidate = await locate(), case let bounds = candidate.bounds else { return fail("The response or its Copy button disappeared while scrolling.") }
            guard pointerOwned() else { return fail("Copy stopped because input changed.") }
            lastSelectionTrace.append("attempt=\(attempt) button=\(bounds)")
            if let point = ModernResponseCapturePolicy.clickPoint(button: bounds, window: candidate.viewport) {
                var hit: AXUIElement?
                var pid: pid_t = 0
                guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                      let hit, AXUIElementGetPid(hit, &pid) == .success, pid == expected.processID else {
                    return fail("Another app covers the Copy button. Move it aside and retry.")
                }
                // Chromium may hit-test to a broad parent, so do not require AX object identity.
                if let role: String = boundedAttribute(hit, kAXRoleAttribute), role == "AXButton",
                   !["copy", "copy response"].contains((boundedAttribute(hit, kAXTitleAttribute) as String? ?? boundedAttribute(hit, kAXDescriptionAttribute) as String? ?? "").lowercased()) {
                    return fail("A different button occupies the expected position; no click was sent.")
                }
                guard CGWarpMouseCursorPosition(point) == .success else { return fail("The pointer could not be positioned.") }
                parked = point
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(120))
                guard await current(), pointerOwned(), let fresh = await locate(), case let freshBounds = fresh.bounds,
                      abs(freshBounds.midX - point.x) <= 2, abs(freshBounds.midY - point.y) <= 2 else { continue }
                guard pointerOwned() else { return fail("Copy stopped because input changed.") }
                let board = NSPasteboard.general
                let before = board.changeCount
                guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return fail("Mouse input is unavailable.") }
                down.setIntegerValueField(.mouseEventClickState, value: 1)
                up.setIntegerValueField(.mouseEventClickState, value: 1)
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                lastSelectionTrace.append("physical-click=\(point)")
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(75))
                    if board.changeCount != before || Task.isCancelled { break }
                }
                guard await current(), board.changeCount != before else { return fail("The visible Copy button was clicked, but the clipboard did not change.") }
                var packet = ResponseClipboardPacket.read(from: board, prompt: entry.fullText, selection: nil)
                packet.selectionMethod = "native-footer-click"
                packet.selectionTrace = lastSelectionTrace
                guard !packet.items.isEmpty else { return fail("The click produced no clipboard formats.") }
                return packet
            }
            if !usedNextPrompt, let next = candidate.nextPrompt {
                let result = await worker.scrollToVisible(.init(element: next), expected: expected)
                lastSelectionTrace.append("scroll-next-prompt=\(result)")
                usedNextPrompt = true
                continue
            }
            // Correct for a footer clipped at a window edge or hidden behind the composer.
            let point = CGPoint(x: candidate.viewport.midX, y: candidate.viewport.midY)
            guard CGWarpMouseCursorPosition(point) == .success else { return fail("The pointer could not be positioned for scrolling.") }
            parked = point
            let amount: Int32 = bounds.minY <= candidate.viewport.minY + 2 ? 100 : -100
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { return fail("Scrolling is unavailable.") }
            event.location = point
            event.post(tap: .cghidEventTap)
        }
        return fail("The selected response's Copy button could not be brought fully into view. Show its footer, then retry.")
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

}
