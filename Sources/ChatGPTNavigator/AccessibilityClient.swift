import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct ConversationScrollSession {
    let scrollArea: AXUIElement
    let scrollBar: AXUIElement
    let originalFraction: Double
}

struct ConversationIndexSample {
    let snapshot: ConversationSnapshot
    let evidence: IndexPageEvidence
}

final class PhysicalIndexScrollSession {
    let processIdentifier: pid_t
    let originalPointer: CGPoint
    let parkedPointer: CGPoint
    var hasEnded = false

    init(processIdentifier: pid_t, originalPointer: CGPoint, parkedPointer: CGPoint) {
        self.processIdentifier = processIdentifier
        self.originalPointer = originalPointer
        self.parkedPointer = parkedPointer
    }
}

final class AccessibilityClient {
    static let classicBundleIdentifier = "com.openai.chat"
    static let indexWheelPulseCount = 6
    static let indexWheelPulseIntervalMilliseconds = 15
    static let indexWheelBurstMilliseconds = indexWheelPulseCount * indexWheelPulseIntervalMilliseconds

    private let maximumNodes = 10_000
    private let maximumDepth = 55

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestTrustPrompt() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func runningClassicApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.classicBundleIdentifier
        ).first
    }

    func scan() -> ConversationSnapshot? {
        guard let application = runningClassicApplication() else { return nil }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = preferredWindow(in: applicationElement) else {
            return ConversationSnapshot(
                entries: [],
                chatWindowFrame: nil,
                usedStructuralOwnership: false,
                diagnosticLines: ["No accessible ChatGPT window was found."]
            )
        }

        let windowFrame = frame(of: window)
        var nodes: [ScannedNode] = []
        let conversationRoot = preferredConversationRoot(
            in: window,
            windowFrame: windowFrame
        )
        if let conversationRoot {
            nodes.append(
                contentsOf: collectNodes(
                    from: conversationRoot,
                    windowFrame: windowFrame,
                    forceConversationContext: true
                )
            )
        }

        // Classic does not expose every conversation through the same container.
        // Scanning the whole window as a second source catches chats that omit a
        // dedicated AXScrollArea or use a canvas/web-area hierarchy.
        nodes.append(contentsOf: collectNodes(from: window, windowFrame: windowFrame))

        var diagnostics: [String] = []
        for node in nodes {
            if diagnostics.count < 180, let line = diagnosticLine(for: node) {
                diagnostics.append(line)
            }
        }

        let scrollFraction = conversationRoot.flatMap(conversationScrollFraction(in:))
        let userEntries = userMessageEntries(
            from: nodes,
            scrollFraction: scrollFraction
        )
        diagnostics.append(
            "ownership=parent AXGroup custom action Name:Edit matched=\(userEntries.count)"
        )

        return ConversationSnapshot(
            entries: sortByReadingOrder(userEntries),
            chatWindowFrame: windowFrame,
            usedStructuralOwnership: !userEntries.isEmpty,
            diagnosticLines: diagnostics,
            viewportFrame: conversationRoot.flatMap { root in
                frame(of: root).map { $0.intersection(windowFrame ?? $0) }
            },
            scrollFraction: scrollFraction
        )
    }

    /// Fast path used while indexing. The normal refresh intentionally scans
    /// both the conversation root and the whole window for compatibility, but
    /// doing that for every virtualized page is unnecessarily expensive once
    /// the conversation scroll area has already been identified.
    func scanConversation(in session: ConversationScrollSession) -> ConversationSnapshot {
        let nodes = collectNodes(
            from: session.scrollArea,
            windowFrame: frame(of: session.scrollArea),
            forceConversationContext: true
        )
        let fraction = currentScrollFraction(in: session)
        let userEntries = userMessageEntries(
            from: nodes,
            scrollFraction: fraction
        )

        return ConversationSnapshot(
            entries: sortByReadingOrder(userEntries),
            chatWindowFrame: nil,
            usedStructuralOwnership: !userEntries.isEmpty,
            diagnosticLines: [],
            viewportFrame: frame(of: session.scrollArea),
            scrollFraction: fraction
        )
    }

    @MainActor
    func navigateUsingFind(to promptText: String) async -> String? {
        guard let application = runningClassicApplication() else {
            return "ChatGPT Classic is no longer running."
        }
        guard isTrusted else {
            return "Accessibility permission is required for Command-F navigation."
        }
        guard let query = findQuery(from: promptText) else {
            return "The selected prompt did not contain searchable text."
        }

        application.activate()
        try? await Task.sleep(for: .milliseconds(40))

        let processIdentifier = application.processIdentifier
        guard postKey(
            virtualKey: 3,
            flags: .maskCommand,
            to: processIdentifier
        ) else {
            return "Could not open Find in ChatGPT Classic."
        }
        try? await Task.sleep(for: .milliseconds(100))
        let scrollSession = beginConversationScrollSession()

        let startingFraction = scrollSession.flatMap(
            currentScrollFraction(in:)
        )
        guard await enterFindQuery(
            query,
            processIdentifier: processIdentifier
        ) else {
            return "Could not enter the selected prompt into Find."
        }

        if await waitForFindNavigation(
            promptText: promptText,
            startingFraction: startingFraction,
            session: scrollSession,
            attempts: 5
        ) {
            await finishFindNavigation(
                promptText: promptText,
                processIdentifier: processIdentifier
            )
            return nil
        }

        _ = postKey(virtualKey: 36, to: processIdentifier)
        if await waitForFindNavigation(
            promptText: promptText,
            startingFraction: startingFraction,
            session: scrollSession,
            attempts: 5
        ) {
            await finishFindNavigation(
                promptText: promptText,
                processIdentifier: processIdentifier
            )
            return nil
        }
        _ = postKey(virtualKey: 53, to: processIdentifier)
        return nil
    }

    /// Captures the assistant message immediately following a visible user
    /// prompt. ChatGPT's own Copy accessibility action is preferred because it
    /// preserves code and line breaks; accessible static text is the fallback.
    @MainActor
    func captureResponse(following promptText: String) async -> String? {
        for _ in 0..<4 {
            guard !Task.isCancelled else { return nil }
            if let candidate = assistantResponseCandidate(following: promptText) {
                if let copied = await copiedResponse(from: candidate), !copied.isEmpty {
                    return copied
                }
                if !candidate.fallbackText.isEmpty {
                    return candidate.fallbackText
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return nil
    }

    private struct AssistantResponseCandidate {
        let container: AXUIElement
        let copyAction: String
        let fallbackText: String
        let frame: CGRect?
    }

    private func assistantResponseCandidate(
        following promptText: String
    ) -> AssistantResponseCandidate? {
        guard let application = runningClassicApplication() else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = preferredWindow(in: applicationElement),
              let conversationRoot = preferredConversationRoot(
                  in: window,
                  windowFrame: frame(of: window)
              ) else { return nil }

        let viewport = frame(of: conversationRoot)
        let nodes = collectNodes(
            from: conversationRoot,
            windowFrame: viewport,
            forceConversationContext: true
        )
        let target = normalize(promptText)
        guard let prompt = userMessageEntries(
            from: nodes,
            scrollFraction: nil
        ).first(where: { normalize($0.fullText) == target }) else {
            return nil
        }

        var candidates: [AssistantResponseCandidate] = []
        var seenContainers = Set<CFHashCode>()

        for node in nodes {
            guard stringAttribute(node.element, kAXRoleAttribute) == kAXStaticTextRole as String,
                  let container = assistantMessageContainer(startingAt: node.element),
                  seenContainers.insert(CFHash(container)).inserted,
                  let copyAction = assistantCopyAction(on: container) else {
                continue
            }

            var textElements = descendantStaticTextElements(of: container)
            if !textElements.contains(where: { CFHash($0) == CFHash(node.element) }) {
                textElements.insert(node.element, at: 0)
            }
            let fragments = coalesceMessageFragments(
                textElements.compactMap { element in
                    let description = stringAttribute(element, kAXDescriptionAttribute)
                    return description.map(normalize).flatMap { $0.isEmpty ? nil : $0 }
                        ?? bestText(for: element).map(normalize).flatMap {
                            $0.isEmpty ? nil : $0
                        }
                }
            )
            let fallbackText = fragments.joined(separator: "\n")
            guard !fallbackText.isEmpty else { continue }

            candidates.append(
                AssistantResponseCandidate(
                    container: container,
                    copyAction: copyAction,
                    fallbackText: fallbackText,
                    frame: frame(of: container)
                )
            )
        }

        if let promptFrame = prompt.frame {
            let followingCandidates = candidates.filter { candidate in
                    guard let candidateFrame = candidate.frame else { return false }
                    return candidateFrame.midY > promptFrame.midY
                }
            if let closestFollowingResponse = followingCandidates.min(
                by: { first, second in
                    (first.frame?.midY ?? CGFloat.greatestFiniteMagnitude) <
                        (second.frame?.midY ?? CGFloat.greatestFiniteMagnitude)
                }
            ) {
                return closestFollowingResponse
            }
        }

        return candidates.first
    }

    private func assistantMessageContainer(
        startingAt element: AXUIElement
    ) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { break }
            if assistantCopyAction(on: candidate) != nil,
               !hasCustomAction(named: "Edit", on: candidate),
               hasConversationAncestorChain(candidate) {
                return candidate
            }
            current = attribute(candidate, kAXParentAttribute)
        }
        return nil
    }

    private func assistantCopyAction(on element: AXUIElement) -> String? {
        actionNames(of: element).first { action in
            guard let name = customActionName(from: action)?.lowercased() else {
                return false
            }
            return name == "copy" || name == "copy response"
        }
    }

    @MainActor
    private func copiedResponse(
        from candidate: AssistantResponseCandidate
    ) async -> String? {
        let pasteboard = NSPasteboard.general
        let savedPasteboard = PasteboardSnapshot(pasteboard: pasteboard)
        let startingChangeCount = pasteboard.changeCount

        guard AXUIElementPerformAction(
            candidate.container,
            candidate.copyAction as CFString
        ) == .success else {
            return nil
        }

        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { break }
            if pasteboard.changeCount != startingChangeCount {
                break
            }
        }

        guard pasteboard.changeCount != startingChangeCount else { return nil }
        let capturedChangeCount = pasteboard.changeCount
        let copied = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        savedPasteboard.restore(
            to: pasteboard,
            ifUnchangedSince: capturedChangeCount
        )
        return copied
    }

    @MainActor
    private func enterFindQuery(
        _ query: String,
        processIdentifier: pid_t
    ) async -> Bool {
        guard postKey(
            virtualKey: 0,
            flags: .maskCommand,
            to: processIdentifier
        ) else {
            return false
        }
        try? await Task.sleep(for: .milliseconds(30))

        let pasteboard = NSPasteboard.general
        let savedPasteboard = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(query, forType: .string) else {
            savedPasteboard.restore(to: pasteboard)
            return false
        }
        let temporaryPasteboardChange = pasteboard.changeCount

        guard postKey(
            virtualKey: 9,
            flags: .maskCommand,
            to: processIdentifier
        ) else {
            savedPasteboard.restore(
                to: pasteboard,
                ifUnchangedSince: temporaryPasteboardChange
            )
            return false
        }
        try? await Task.sleep(for: .milliseconds(120))
        savedPasteboard.restore(
            to: pasteboard,
            ifUnchangedSince: temporaryPasteboardChange
        )
        return true
    }

    @MainActor
    private func waitForFindNavigation(
        promptText: String,
        startingFraction: Double?,
        session: ConversationScrollSession?,
        attempts: Int
    ) async -> Bool {
        var lastFraction = startingFraction
        var sawMovement = false
        var stableMovementChecks = 0

        for attempt in 0..<attempts {
            try? await Task.sleep(for: .milliseconds(90))

            if attempt.isMultiple(of: 2), isPromptVisible(promptText) {
                return true
            }

            guard let session,
                  let fraction = currentScrollFraction(in: session) else {
                continue
            }

            if let startingFraction,
               abs(fraction - startingFraction) > 0.000_01 {
                sawMovement = true
            }
            if sawMovement, let lastFraction {
                if abs(fraction - lastFraction) <= 0.000_01 {
                    stableMovementChecks += 1
                } else {
                    stableMovementChecks = 0
                }
                if stableMovementChecks >= 2 {
                    return true
                }
            }
            lastFraction = fraction
        }

        return isPromptVisible(promptText)
    }

    @MainActor
    private func finishFindNavigation(
        promptText: String,
        processIdentifier: pid_t
    ) async {
        _ = postKey(virtualKey: 53, to: processIdentifier)
        try? await Task.sleep(for: .milliseconds(60))
        await centerPromptInViewport(
            promptText,
            processIdentifier: processIdentifier
        )
    }

    private func findQuery(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map(normalize)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let base = lines.first(where: { $0.count >= 40 })
            ?? lines.max(by: { $0.count < $1.count })!
        let query = String(base.prefix(80))
        return query.isEmpty ? nil : query
    }

    @MainActor
    private func centerPromptInViewport(
        _ promptText: String,
        processIdentifier: pid_t
    ) async {
        var missingGeometryRetries = 4
        for _ in 0..<12 {
            guard let geometry = promptGeometry(promptText) else {
                guard missingGeometryRetries > 0 else { return }
                missingGeometryRetries -= 1
                try? await Task.sleep(for: .milliseconds(80))
                continue
            }
            missingGeometryRetries = 4
            let verticalInset = min(90, geometry.viewportFrame.height * 0.12)
            let visibleViewport = geometry.viewportFrame.insetBy(
                dx: 0,
                dy: verticalInset
            )
            let offset = geometry.entryFrame.midY - visibleViewport.midY

            // The prompt's center is safely inside the usable viewport.
            guard !visibleViewport.contains(
                CGPoint(x: visibleViewport.midX, y: geometry.entryFrame.midY)
            ) else { return }

            let magnitude = min(550, max(120, abs(offset)))
            // AX screen coordinates increase downward. A prompt below the
            // viewport therefore needs a downward (negative-wheel) scroll.
            let wheelPixels = Int32((offset > 0 ? -magnitude : magnitude).rounded())
            guard postScroll(
                pixels: wheelPixels,
                at: CGPoint(
                    x: geometry.viewportFrame.midX,
                    y: geometry.viewportFrame.midY
                ),
                to: processIdentifier
            ) else { return }
            try? await Task.sleep(for: .milliseconds(90))
        }
    }

    private func isPromptVisible(_ promptText: String) -> Bool {
        guard let geometry = promptGeometry(promptText) else { return false }
        return geometry.entryFrame.intersects(geometry.viewportFrame)
    }

    /// Returns matching geometry even when the materialized prompt currently
    /// lies just outside the actual conversation viewport.
    private func promptGeometry(
        _ promptText: String
    ) -> (entryFrame: CGRect, viewportFrame: CGRect)? {
        guard let application = runningClassicApplication() else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = preferredWindow(in: applicationElement),
              let conversationRoot = preferredConversationRoot(
                  in: window,
                  windowFrame: frame(of: window)
              ),
              let viewportFrame = frame(of: conversationRoot) else {
            return nil
        }

        let nodes = collectNodes(
            from: conversationRoot,
            windowFrame: viewportFrame,
            forceConversationContext: true
        )
        let target = normalize(promptText)
        guard let match = userMessageEntries(
            from: nodes,
            scrollFraction: nil
        ).first(where: { entry in
            normalize(entry.fullText) == target && entry.frame != nil
        }), let entryFrame = match.frame else {
            return nil
        }
        return (entryFrame, viewportFrame)
    }

    private func postScroll(
        pixels: Int32,
        at location: CGPoint,
        to processIdentifier: pid_t
    ) -> Bool {
        guard pixels != 0,
              let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .pixel,
                  wheelCount: 1,
                  wheel1: pixels,
                  wheel2: 0,
                  wheel3: 0
              ) else {
            return false
        }

        event.location = location
        event.postToPid(processIdentifier)
        return true
    }

    private func postKey(
        virtualKey: CGKeyCode,
        flags: CGEventFlags = [],
        to processIdentifier: pid_t
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: virtualKey,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: virtualKey,
                  keyDown: false
              ) else {
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }

        func restore(
            to pasteboard: NSPasteboard,
            ifUnchangedSince expectedChangeCount: Int? = nil
        ) {
            if let expectedChangeCount,
               pasteboard.changeCount != expectedChangeCount {
                return
            }
            pasteboard.clearContents()
            let restoredItems = items.map { storedItem in
                let item = NSPasteboardItem()
                for (type, data) in storedItem {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    func beginConversationScrollSession() -> ConversationScrollSession? {
        guard let application = runningClassicApplication() else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = preferredWindow(in: applicationElement),
              let scrollArea = preferredConversationRoot(
                  in: window,
                  windowFrame: frame(of: window)
              ),
              let scrollBar = conversationScrollBar(in: scrollArea),
              let originalFraction = numericAttribute(
                  scrollBar,
                  kAXValueAttribute
              ) else {
            return nil
        }

        application.activate()
        return ConversationScrollSession(
            scrollArea: scrollArea,
            scrollBar: scrollBar,
            originalFraction: originalFraction
        )
    }

    func currentScrollFraction(in session: ConversationScrollSession) -> Double? {
        numericAttribute(session.scrollBar, kAXValueAttribute)
    }

    /// Reacquire containers after virtualization replaces AX elements, carrying
    /// the original restore position across those replacements. Does not activate
    /// or raise ChatGPT on each refresh.
    func refreshIndexScrollSession(
        _ original: ConversationScrollSession
    ) -> ConversationScrollSession? {
        guard let application = runningClassicApplication() else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = preferredWindow(in: app),
              let root = preferredConversationRoot(in: window, windowFrame: frame(of: window)),
              let bar = conversationScrollBar(in: root),
              numericAttribute(bar, kAXValueAttribute) != nil else { return nil }
        return ConversationScrollSession(
            scrollArea: root, scrollBar: bar,
            originalFraction: original.originalFraction
        )
    }

    func sampleForIndexing(in session: ConversationScrollSession) -> ConversationIndexSample {
        let viewport = frame(of: session.scrollArea)
        let nodes = collectNodes(
            from: session.scrollArea, windowFrame: viewport,
            forceConversationContext: true
        )
        let fraction = currentScrollFraction(in: session)
        let userEntries = userMessageEntries(from: nodes, scrollFraction: fraction)
        var visibleHasher = Hasher()
        var loadedHasher = Hasher()
        var visibleCount = 0
        var loadedCount = 0
        var busy = (attribute(session.scrollArea, kAXElementBusyAttribute) as NSNumber?)?.boolValue ?? false
        for node in nodes {
            let role = stringAttribute(node.element, kAXRoleAttribute)
            if role == kAXProgressIndicatorRole as String || role == kAXBusyIndicatorRole as String {
                if let viewport, let nodeFrame = frame(of: node.element), nodeFrame.intersects(viewport) {
                    busy = true
                }
            }
            guard role == kAXStaticTextRole as String,
                  let text = stringAttribute(node.element, kAXDescriptionAttribute)
                    ?? stringAttribute(node.element, kAXValueAttribute),
                  !text.isEmpty else { continue }
            // Include assistant text as well as user text. These hashes exist
            // only in memory; no conversation content is written to diagnostics.
            loadedHasher.combine(text)
            loadedCount += 1
            if let viewport, let nodeFrame = frame(of: node.element),
               nodeFrame.intersects(viewport), nodeFrame.minY.isFinite {
                visibleHasher.combine(text)
                visibleHasher.combine(Int((nodeFrame.minY - viewport.minY) / 8))
                visibleCount += 1
            }
        }
        return ConversationIndexSample(
            snapshot: ConversationSnapshot(
                entries: sortByReadingOrder(userEntries), chatWindowFrame: nil,
                usedStructuralOwnership: !userEntries.isEmpty, diagnosticLines: [],
                viewportFrame: viewport, scrollFraction: fraction
            ),
            evidence: IndexPageEvidence(
                scrollFraction: fraction,
                visibleFingerprint: visibleCount > 0 ? visibleHasher.finalize() : nil,
                loadedFingerprint: loadedCount > 0 ? loadedHasher.finalize() : nil,
                isBusy: busy
            )
        )
    }

    @MainActor
    func beginPhysicalIndexScroll(in session: ConversationScrollSession) async -> PhysicalIndexScrollSession? {
        guard let application = runningClassicApplication(),
              let viewport = frame(of: session.scrollArea), !viewport.isEmpty,
              let originalPointer = CGEvent(source: nil)?.location else { return nil }
        application.activate()
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return nil }
        let target = CGPoint(x: viewport.midX, y: viewport.midY)
        guard pointBelongsToApplication(target, processIdentifier: application.processIdentifier),
              CGWarpMouseCursorPosition(target) == .success else { return nil }
        let moved = CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: target, mouseButton: .left
        )
        moved?.post(tap: .cghidEventTap)
        return PhysicalIndexScrollSession(
            processIdentifier: application.processIdentifier,
            originalPointer: originalPointer, parkedPointer: target
        )
    }

    @MainActor
    func physicalIndexInputIsActive(_ input: PhysicalIndexScrollSession) -> Bool {
        guard !input.hasEnded,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == input.processIdentifier,
              let pointer = CGEvent(source: nil)?.location,
              hypot(pointer.x - input.parkedPointer.x, pointer.y - input.parkedPointer.y) <= 8 else { return false }
        return pointBelongsToApplication(input.parkedPointer, processIdentifier: input.processIdentifier)
    }

    /// Small discrete mouse-wheel notches, rather than a single large precise
    /// scroll. AX extraction runs between complete bursts, never between pulses.
    @MainActor
    func scrollWheelPulseBurst(input: PhysicalIndexScrollSession) async -> Bool {
        guard physicalIndexInputIsActive(input) else { return false }
        for _ in 0..<Self.indexWheelPulseCount {
            // Only user takeover/cancellation can interrupt a burst. AX
            // container replacement or a spinner cannot suppress later notches.
            guard !Task.isCancelled, !input.hasEnded,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == input.processIdentifier,
                  let pointer = CGEvent(source: nil)?.location,
                  hypot(pointer.x - input.parkedPointer.x, pointer.y - input.parkedPointer.y) <= 8,
                  let event = CGEvent(
                      scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                      wheel1: 3, wheel2: 0, wheel3: 0
                  ) else { return false }
            event.location = input.parkedPointer
            event.flags = []
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            event.post(tap: .cghidEventTap)
            do {
                try await Task.sleep(for: .milliseconds(Self.indexWheelPulseIntervalMilliseconds))
            } catch {
                return false
            }
        }
        return true
    }

    func endPhysicalIndexScroll(_ input: PhysicalIndexScrollSession) {
        guard !input.hasEnded else { return }
        input.hasEnded = true
        // If the user took control, leave their pointer where they moved it.
        if let pointer = CGEvent(source: nil)?.location,
           hypot(pointer.x - input.parkedPointer.x, pointer.y - input.parkedPointer.y) <= 8 {
            _ = CGWarpMouseCursorPosition(input.originalPointer)
        }
    }

    private func pointBelongsToApplication(_ point: CGPoint, processIdentifier: pid_t) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit
        ) == .success, let hit else { return false }
        var hitPID: pid_t = 0
        return AXUIElementGetPid(hit, &hitPID) == .success && hitPID == processIdentifier
    }

    @discardableResult
    func setScrollFraction(
        _ fraction: Double,
        in session: ConversationScrollSession
    ) -> Bool {
        let clamped = min(1, max(0, fraction))
        return AXUIElementSetAttributeValue(
            session.scrollBar,
            kAXValueAttribute as CFString,
            NSNumber(value: clamped)
        ) == .success
    }

    @discardableResult
    func scrollDownOnePage(in session: ConversationScrollSession) -> Bool {
        let pageError = AXUIElementPerformAction(
            session.scrollArea,
            "AXScrollDownByPage" as CFString
        )
        if pageError == .success {
            return true
        }

        // Some Classic releases expose a writable normalized scrollbar but do
        // not advertise the page action on the containing AXScrollArea.
        guard let current = currentScrollFraction(in: session), current < 1 else {
            return false
        }
        return setScrollFraction(min(1, current + 0.025), in: session)
    }

    @discardableResult
    func scrollUpOnePage(in session: ConversationScrollSession) -> Bool {
        let pageError = AXUIElementPerformAction(
            session.scrollArea,
            "AXScrollUpByPage" as CFString
        )
        if pageError == .success {
            return true
        }

        guard let current = currentScrollFraction(in: session), current > 0 else {
            return false
        }
        return setScrollFraction(max(0, current - 0.025), in: session)
    }

    func restoreScrollPosition(_ session: ConversationScrollSession) {
        _ = setScrollFraction(session.originalFraction, in: session)
    }

    private struct ScannedNode {
        let element: AXUIElement
        let depth: Int
        let inUserMessageContext: Bool
        let inConversationContext: Bool
    }

    private func userMessageEntries(
        from nodes: [ScannedNode],
        scrollFraction: Double?
    ) -> [NavigationEntry] {
        var seenContainers = Set<CFHashCode>()
        var entries: [NavigationEntry] = []

        for node in nodes {
            let textElement = node.element
            guard stringAttribute(textElement, kAXRoleAttribute) == kAXStaticTextRole as String else {
                continue
            }
            guard let container: AXUIElement = attribute(textElement, kAXParentAttribute),
                  stringAttribute(container, kAXRoleAttribute) == kAXGroupRole as String else {
                continue
            }

            let containerHash = CFHash(container)
            guard hasCustomAction(named: "Edit", on: container) else { continue }
            guard hasConversationAncestorChain(container) else { continue }
            guard seenContainers.insert(containerHash).inserted else { continue }

            var textElements = descendantStaticTextElements(of: container)
            if !textElements.contains(where: { CFHash($0) == CFHash(textElement) }) {
                textElements.insert(textElement, at: 0)
            }

            let fragments = coalesceMessageFragments(
                textElements.compactMap { element in
                    let description = stringAttribute(element, kAXDescriptionAttribute)
                    return description.map(normalize).flatMap { $0.isEmpty ? nil : $0 }
                        ?? bestText(for: element).map(normalize).flatMap {
                            $0.isEmpty ? nil : $0
                        }
                }
            )
            guard !fragments.isEmpty else { continue }

            let completeText = fragments.joined(separator: "\n")
            entries.append(
                NavigationEntry(
                    id: "user-message:\(completeText)",
                    preview: preview(completeText),
                    fullText: completeText,
                    confidence: .userMessage,
                    sourceRole: "AXGroup[Name:Edit]",
                    element: textElement,
                    frame: frame(of: container) ?? frame(of: textElement),
                    scrollFraction: scrollFraction
                )
            )
        }
        return entries
    }

    private func hasCustomAction(named expectedName: String, on element: AXUIElement) -> Bool {
        actionNames(of: element).contains { action in
            guard let customName = customActionName(from: action) else { return false }
            return customName.compare(
                expectedName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }

    private func customActionName(from action: String) -> String? {
        guard let firstLine = action.split(separator: "\n", maxSplits: 1).first else {
            return nil
        }
        let prefix = "Name:"
        guard firstLine.hasPrefix(prefix) else { return nil }
        return String(firstLine.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasConversationAncestorChain(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var foundHostingView = false
        var foundCollectionList = false
        var foundScrollArea = false

        for _ in 0..<16 {
            guard let candidate = current else { break }
            let role = stringAttribute(candidate, kAXRoleAttribute)
            let subrole = stringAttribute(candidate, kAXSubroleAttribute)

            if role == kAXGroupRole as String && subrole == "AXHostingView" {
                foundHostingView = true
            }
            if role == kAXListRole as String && subrole == "AXCollectionList" {
                foundCollectionList = true
            }
            if role == kAXScrollAreaRole as String {
                foundScrollArea = true
            }

            current = attribute(candidate, kAXParentAttribute)
        }

        return foundHostingView && foundCollectionList && foundScrollArea
    }

    private func descendantStaticTextElements(of root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = accessibilityChildren(of: root)
            .reversed()
            .map { ($0, 1) }
        var visited = Set<CFHashCode>()

        while let (element, depth) = stack.popLast() {
            guard depth <= 10, result.count < 200 else { continue }
            guard visited.insert(CFHash(element)).inserted else { continue }

            if stringAttribute(element, kAXRoleAttribute) == kAXStaticTextRole as String {
                result.append(element)
            }
            for child in accessibilityChildren(of: element).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return result
    }

    private func coalesceMessageFragments(_ fragments: [String]) -> [String] {
        var result: [String] = []

        for fragment in fragments {
            if result.contains(where: { $0 == fragment || $0.contains(fragment) }) {
                continue
            }
            result.removeAll { fragment.contains($0) }
            result.append(fragment)
        }
        return result
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else { return [] }
        return names as? [String] ?? []
    }

    private func conversationScrollBar(in scrollArea: AXUIElement) -> AXUIElement? {
        if let scrollBar: AXUIElement = attribute(
            scrollArea,
            kAXVerticalScrollBarAttribute
        ) {
            return scrollBar
        }
        return accessibilityChildren(of: scrollArea).first {
            stringAttribute($0, kAXRoleAttribute) == kAXScrollBarRole as String
        }
    }

    private func conversationScrollFraction(in scrollArea: AXUIElement) -> Double? {
        guard let scrollBar = conversationScrollBar(in: scrollArea) else { return nil }
        return numericAttribute(scrollBar, kAXValueAttribute)
    }

    private func numericAttribute(_ element: AXUIElement, _ name: String) -> Double? {
        if let number: NSNumber = attribute(element, name) {
            return number.doubleValue
        }
        if let value: Double = attribute(element, name) {
            return value
        }
        return nil
    }

    private func preferredWindow(in application: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = attribute(application, kAXFocusedWindowAttribute) {
            return focused
        }
        if let main: AXUIElement = attribute(application, kAXMainWindowAttribute) {
            return main
        }

        let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) ?? []
        return windows.max { first, second in
            area(of: first) < area(of: second)
        }
    }

    private func preferredConversationRoot(
        in window: AXUIElement,
        windowFrame: CGRect?
    ) -> AXUIElement? {
        let nodes = collectNodes(
            from: window,
            windowFrame: windowFrame,
            nodeLimit: 1_500,
            depthLimit: 22
        )

        let scrollAreas = nodes.compactMap { node -> (AXUIElement, CGRect)? in
            guard stringAttribute(node.element, kAXRoleAttribute) == kAXScrollAreaRole as String,
                  let elementFrame = frame(of: node.element),
                  elementFrame.width >= 240,
                  elementFrame.height >= 220 else {
                return nil
            }
            return (node.element, elementFrame)
        }

        guard let windowFrame else { return scrollAreas.max { first, second in
            first.1.width * first.1.height < second.1.width * second.1.height
        }?.0 }

        // Reject the chat-history sidebar. If no strong conversation-area
        // candidate exists, the caller falls back to scanning the whole window.
        let conversationAreas = scrollAreas.filter { _, frame in
            frame.maxX > windowFrame.minX + windowFrame.width * 0.72 &&
                frame.width > windowFrame.width * 0.34 &&
                frame.height > windowFrame.height * 0.34
        }

        guard !conversationAreas.isEmpty else { return nil }

        return conversationAreas.max { first, second in
            conversationRootScore(first.1, windowFrame: windowFrame) <
                conversationRootScore(second.1, windowFrame: windowFrame)
        }?.0
    }

    private func conversationRootScore(_ frame: CGRect, windowFrame: CGRect?) -> CGFloat {
        var score = frame.width * frame.height
        if let windowFrame {
            if frame.midX > windowFrame.minX + windowFrame.width * 0.42 {
                score *= 1.8
            }
            if frame.width > windowFrame.width * 0.48 {
                score *= 1.4
            }
        }
        return score
    }

    private func collectNodes(
        from root: AXUIElement,
        windowFrame: CGRect?,
        nodeLimit: Int? = nil,
        depthLimit: Int? = nil,
        forceConversationContext: Bool = false
    ) -> [ScannedNode] {
        let effectiveNodeLimit = nodeLimit ?? maximumNodes
        let effectiveDepthLimit = depthLimit ?? maximumDepth
        var result: [ScannedNode] = []
        var stack: [(AXUIElement, Int, Bool, Bool)] = [
            (root, 0, false, forceConversationContext),
        ]
        var visited = Set<CFHashCode>()

        while let (
            element,
            depth,
            inheritedUserContext,
            inheritedConversationContext
        ) = stack.popLast() {
            guard result.count < effectiveNodeLimit, depth <= effectiveDepthLimit else {
                continue
            }

            let hash = CFHash(element)
            guard visited.insert(hash).inserted else { continue }

            let metadata = [
                stringAttribute(element, kAXIdentifierAttribute),
                stringAttribute(element, kAXDescriptionAttribute),
                stringAttribute(element, kAXTitleAttribute),
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

            let isUserContext = inheritedUserContext ||
                metadata.contains("you said") ||
                metadata.contains("user message") ||
                (metadata.contains("user") && metadata.contains("message"))

            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            let elementFrame = frame(of: element)
            let startsConversationContext = isLikelyConversationContainer(
                role: role,
                frame: elementFrame,
                windowFrame: windowFrame
            )
            let isConversationContext = inheritedConversationContext ||
                startsConversationContext

            result.append(
                ScannedNode(
                    element: element,
                    depth: depth,
                    inUserMessageContext: isUserContext,
                    inConversationContext: isConversationContext
                )
            )

            let children = accessibilityChildren(of: element)
            for child in children.reversed() {
                stack.append((
                    child,
                    depth + 1,
                    isUserContext,
                    isConversationContext
                ))
            }
        }

        return result
    }

    private func bestText(for element: AXUIElement) -> String? {
        let values = [
            stringAttribute(element, kAXValueAttribute),
            stringAttribute(element, kAXTitleAttribute),
            stringAttribute(element, kAXDescriptionAttribute),
            stringAttribute(element, kAXHelpAttribute),
        ]

        return values
            .compactMap { $0 }
            .map(normalize)
            .first(where: isUsefulText)
    }

    private func isUsefulText(_ text: String) -> Bool {
        guard text.count >= 2, text.count <= 4_000 else { return false }
        let ignored = [
            "chatgpt", "new chat", "search chats", "send message",
            "voice mode", "attach files", "close", "minimize", "zoom",
        ]
        return !ignored.contains(text.lowercased())
    }

    private func isLikelyConversationContainer(
        role: String,
        frame: CGRect?,
        windowFrame: CGRect?
    ) -> Bool {
        guard let frame, let windowFrame else { return false }
        let containerRoles = [
            kAXScrollAreaRole as String,
            kAXGroupRole as String,
            "AXWebArea",
            "AXList",
        ]
        guard containerRoles.contains(role) else { return false }

        return frame.maxX > windowFrame.minX + windowFrame.width * 0.74 &&
            frame.width > windowFrame.width * 0.34 &&
            frame.height > windowFrame.height * 0.34
    }

    private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
        let childAttributes = [
            kAXChildrenAttribute,
            "AXVisibleChildren",
            "AXContents",
            "AXRows",
        ]
        var result: [AXUIElement] = []
        var seen = Set<CFHashCode>()

        for attributeName in childAttributes {
            let children: [AXUIElement] = attribute(element, attributeName) ?? []
            for child in children where seen.insert(CFHash(child)).inserted {
                result.append(child)
            }
        }
        return result
    }

    private func sortByReadingOrder(_ entries: [NavigationEntry]) -> [NavigationEntry] {
        entries.enumerated().sorted { firstItem, secondItem in
            let first = firstItem.element
            let second = secondItem.element
            switch (first.frame, second.frame) {
            case let (.some(firstFrame), .some(secondFrame)):
                if firstFrame.minY != secondFrame.minY {
                    return firstFrame.minY < secondFrame.minY
                }
                return firstItem.offset < secondItem.offset
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return firstItem.offset < secondItem.offset
            }
        }.map(\.element)
    }

    private func preview(_ text: String) -> String {
        let normalized = normalize(text)
        guard normalized.count > 100 else { return normalized }
        return String(normalized.prefix(97)) + "…"
    }

    private func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func diagnosticLine(for node: ScannedNode) -> String? {
        guard let text = bestText(for: node.element) else { return nil }
        let role = stringAttribute(node.element, kAXRoleAttribute) ?? "unknown"
        let identifier = stringAttribute(node.element, kAXIdentifierAttribute) ?? "—"
        let frameText: String
        if let frame = frame(of: node.element) {
            frameText = "x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
        } else {
            frameText = "frame=none"
        }
        return "depth=\(node.depth) role=\(role) id=\(identifier) conversation=\(node.inConversationContext) \(frameText) text=\(preview(text))"
    }

    private func area(of element: AXUIElement) -> CGFloat {
        guard let frame = frame(of: element) else { return 0 }
        return frame.width * frame.height
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        if let string: String = attribute(element, name) {
            return string
        }
        if let attributedString: NSAttributedString = attribute(element, name) {
            return attributedString.string
        }
        return nil
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value else { return nil }
        return value as? T
    }
}
