import AppKit
import ApplicationServices

/// Invoked only by a user's row click. Never targets a cached Accessibility
/// element, and never sends text until the app's focused Find field is verified.
@MainActor
final class ModernFindNavigator {
    private let client: ModernAccessibilityClient
    private(set) var lastDiagnostic: [String] = []
    private(set) var lastSucceeded = false
    private var continuationCheck: (() -> Bool)?
    private var deadline: TimeInterval = .infinity

    init(client: ModernAccessibilityClient) { self.client = client }

    private enum Failure: Error {
        case stopped, timedOut, changedChat, focusChanged, findUnavailable, queryChanged, notFound
        var message: String {
            switch self {
            case .stopped: return "Navigation stopped."
            case .timedOut: return "Navigation timed out. ChatGPT may still be loading. Try the prompt again."
            case .changedChat: return "The chat or window changed. Click the row again in the intended chat."
            case .focusChanged: return "Navigation stopped because focus changed."
            case .findUnavailable:
                return "The Find box wasn't recognized. Open Command-F in ChatGPT, then save a diagnostic snapshot in Navigator."
            case .queryChanged: return "Navigation stopped because the Find box changed."
            case .notFound: return "Find opened, but Navigator couldn't confirm a matching prompt in view."
            }
        }
    }

    func navigate(to target: NavigationEntry, context: ModernConversationContext,
                  continueWhile: (() -> Bool)? = nil) async -> String {
        lastDiagnostic = []
        lastSucceeded = false
        continuationCheck = continueWhile
        deadline = ProcessInfo.processInfo.systemUptime + 15
        defer { continuationCheck = nil }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: ModernAccessibilityClient.bundleIdentifier
        ).first, app.processIdentifier == context.processID,
              let query = ModernNavigationPolicy.query(for: target.fullText) else {
            return "Open the remembered conversation in ChatGPT first."
        }
        var ownedField: AXUIElement?
        do {
            try await verifyContext(context)
            app.activate(options: [])
            try await pause(180)
            // Always run Find, even if Accessibility reports the target as
            // visible. Chromium can expose offscreen content with in-window
            // frames, so that estimate must never skip the requested search.
            try await verifyContext(context, requireFrontmost: true)
            try postKey(3, flags: .maskCommand, pid: context.processID) // Command-F
            var field: ModernFindField?
            for _ in 0..<8 {
                try await pause(90)
                try await verifyContext(context, requireFrontmost: true)
                if let candidate = await focusedFindField(pid: context.processID) {
                    field = candidate
                    break
                }
            }
            guard let field else { throw Failure.findUnavailable }
            // Paste only while this exact verified Find control retains focus.
            try await paste(query, into: field.element, context: context)
            ownedField = field.element
            for _ in 0..<14 {
                try await pause(180)
                var fresh = try await snapshot(in: context, requireFrontmost: true)
                try await verifyField(field.element, query: query, context: context)
                if visibleTarget(target, in: fresh) {
                    try await closeOwnedFind(field.element, query: query, context: context)
                    ownedField = nil
                    try await pause(120)
                    fresh = try await snapshot(in: context, requireFrontmost: true)
                    guard visibleTarget(target, in: fresh) else {
                        throw Failure.notFound
                    }
                    lastSucceeded = true
                    return "Moved to a matching prompt."
                }
                // Keep the initial Find result. Do not press Return to cycle
                // into another occurrence of an identical prompt.
            }
            throw Failure.notFound
        } catch {
            // Closing is conditional: never Escape a different dialog or field
            // after an app/chat/focus change, and never overwrite a user's edit.
            if let ownedField { try? await closeOwnedFind(ownedField, query: query, context: context) }
            if error is CancellationError { return Failure.stopped.message }
            return (error as? Failure)?.message ?? "Navigation couldn't complete. Try the row again."
        }
    }

    private func snapshot(in expected: ModernConversationContext,
                          requireFrontmost: Bool = false) async throws -> ConversationSnapshot {
        try checkContinuation()
        if requireFrontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier != expected.processID {
            throw Failure.focusChanged
        }
        guard let snapshot = await client.scan(), let key = expected.sessionKey,
              snapshot.modernContext?.sessionKey == key else { throw Failure.changedChat }
        try checkContinuation()
        if requireFrontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier != expected.processID { throw Failure.focusChanged }
        return snapshot
    }

    private func verifyContext(_ expected: ModernConversationContext, requireFrontmost: Bool = false) async throws {
        try checkContinuation()
        if requireFrontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier != expected.processID { throw Failure.focusChanged }
        let probe = await client.probe()
        try checkContinuation()
        guard let key = expected.sessionKey, probe?.context?.sessionKey == key else { throw Failure.changedChat }
        if requireFrontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier != expected.processID { throw Failure.focusChanged }
    }

    private func visibleTarget(_ target: NavigationEntry, in snapshot: ConversationSnapshot) -> Bool {
        guard let viewport = snapshot.viewportFrame, !viewport.isNull, !viewport.isEmpty else { return false }
        let observations = snapshot.entries.map { ModernPromptObservation(text: $0.fullText) }
        let matches = ModernNavigationPolicy.matchingIndices(text: target.fullText, entries: observations)
        // Find chooses the occurrence. Accept any complete text match in view;
        // cached row IDs and native message IDs do not constrain that choice.
        return matches.contains { index in
            guard let frame = snapshot.entries[index].frame, !frame.isNull, !frame.isEmpty else { return false }
            return ModernNavigationPolicy.isVisible(frame: frame, viewport: viewport)
        }
    }

    private func focusedFindField(pid: pid_t) async -> ModernFindField? {
        let result = await client.worker.findField(pid: pid)
        if let result { lastDiagnostic = result.diagnostics }
        return result
    }

    func focusedFieldDiagnostic() -> [String] { lastDiagnostic }

    private func verifyField(_ element: AXUIElement, query: String? = nil,
                             context: ModernConversationContext) async throws {
        try await verifyContext(context, requireFrontmost: true)
        guard let current = await focusedFindField(pid: context.processID),
              CFEqual(element, current.element) else { throw Failure.focusChanged }
        try checkContinuation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processID else { throw Failure.focusChanged }
        if let query, current.value != query { throw Failure.queryChanged }
    }

    private func paste(_ query: String, into field: AXUIElement,
                       context: ModernConversationContext) async throws {
        try await verifyField(field, context: context)
        try postKey(0, flags: .maskCommand, pid: context.processID) // Command-A
        try await pause(30)
        try await verifyField(field, context: context)
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        let didSetQuery = board.setString(query, forType: .string)
        let ownedCount = board.changeCount
        defer {
            // Respect any copy the user made while this task was suspended.
            if board.changeCount == ownedCount {
                let items = saved.map { representations in
                    let item = NSPasteboardItem()
                    for (type, data) in representations { item.setData(data, forType: type) }
                    return item
                }
                board.clearContents()
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        guard didSetQuery else { throw Failure.findUnavailable }
        try await verifyField(field, context: context)
        try postKey(9, flags: .maskCommand, pid: context.processID) // Command-V
        try await pause(160)
        try await verifyField(field, query: query, context: context)
    }

    private func closeOwnedFind(_ field: AXUIElement, query: String,
                                context: ModernConversationContext) async throws {
        try await verifyField(field, query: query, context: context)
        try postKey(53, flags: [], pid: context.processID) // Escape
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags, pid: pid_t) throws {
        try checkContinuation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw Failure.focusChanged
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private func checkContinuation() throws {
        try Task.checkCancellation()
        if continuationCheck?() == false { throw Failure.stopped }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure.timedOut }
    }

    private func pause(_ milliseconds: UInt64) async throws {
        try checkContinuation()
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        try checkContinuation()
    }
}
