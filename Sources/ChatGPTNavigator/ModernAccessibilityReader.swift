import AppKit
import ApplicationServices
import Foundation

/// Confined to ModernAXWorker. No renderer traversal runs on the UI actor.
final class ModernAccessibilityReader {
    static let bundleIdentifier = "com.openai.codex"
    private let nodeLimit = 12_000
    private let depthLimit = 90
    private var activation = ModernRendererActivation()

    private var recovery = ModernRendererRecovery()
    private var budget: ModernReadBudget?
    private var cancellation: ModernReadCancellation?

    func requestRecovery() { recovery = ModernRendererRecovery() }

    private func enableRendererAccessibility(for app: NSRunningApplication, application: AXUIElement, window: AXUIElement? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let identity = "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
        guard recovery.shouldRequest(identity: identity, now: now), mayRead else { return }
        var activation = self.activation
        let accepted = activation.request(process: identity, windowAvailable: window != nil,
            forceEnhanced: recovery.attempts > 0,
            set: { target, key in
                let element = target == .application ? application : window!
                guard self.prepare(element) else { return .cannotComplete }
                let error = AXUIElementSetAttributeValue(element, key as CFString, kCFBooleanTrue)
                self.record(error)
                return error
            }, read: { target, key in
                let element = target == .application ? application : window!
                return self.attribute(element, key)
            })
        self.activation = activation
        recovery.didRequest(succeeded: accepted, now: now)
    }

    private var rendererAccessibilityDiagnostic: String {
        activation.diagnostic + " attempts=\(recovery.attempts)"
    }

    struct Node {
        let element: AXUIElement
        let role: String
        let text: String
        let depth: Int
    }
    struct Walk {
        let nodes: [Node]
        let truncated: Bool
    }

    func read(options: ModernScanOptions, cancellation: ModernReadCancellation) -> ConversationSnapshot? {
        self.cancellation = cancellation
        budget = ModernReadBudget(duration: options.diagnostics ? 8 : (options.responses || options.indexing ? 5 : 3))
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.15)
        defer { budget = nil; self.cancellation = nil }
        let result = scan(includeLocation: options.location, includeIndexing: options.indexing,
                          includeDiagnostics: options.diagnostics, includeResponses: options.responses)
        guard mayRead else {
            recovery.observedContent(available: false)
            return ConversationSnapshot(entries: [], chatWindowFrame: result?.chatWindowFrame,
                usedStructuralOwnership: false, diagnosticLines: (result?.diagnosticLines ?? []) + ["scan-stopped=\(budget?.failure?.rawValue ?? "cancelled")"],
                modernScanFailure: budget?.failure?.rawValue ?? "cancelled")
        }
        return result
    }

    private var mayRead: Bool {
        guard var current = budget else { return true }
        let allowed = current.allowRead(cancelled: cancellation?.isCancelled == true)
        budget = current
        return allowed
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        guard mayRead else { return false }
        let remaining = budget.map { max(0.001, $0.deadline - ProcessInfo.processInfo.systemUptime) } ?? 0.15
        return AXUIElementSetMessagingTimeout(element, Float(min(0.15, remaining))) == .success
    }

    private func record(_ error: AXError) {
        budget?.record(error)
    }

    func scan(includeLocation: Bool = false, includeIndexing: Bool = false, includeDiagnostics: Bool = false, includeResponses: Bool = false) -> ConversationSnapshot? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).first else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) ?? []
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute)
                ?? attribute(application, kAXMainWindowAttribute)
                ?? windows.first else {
            enableRendererAccessibility(for: app, application: application)
            var diagnostics = ["target=\(Self.bundleIdentifier) version=\(appVersion(app))", rendererAccessibilityDiagnostic, "No accessible ChatGPT window."]
            if includeDiagnostics {
                for key in [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                    guard prepare(application) else { break }
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(application, key as CFString, &value)
                    diagnostics.append("\(key) error=\(error.rawValue) value-present=\(value != nil)")
                }
                diagnostics += detailedDiagnostics(walk(application), window: nil)
            }
            return empty(diagnostics)
        }
        enableRendererAccessibility(for: app, application: application, window: window)
        let windowFrame = frame(window)
        // Prefer the named landmark observed in the Inspector screenshots.
        // This keeps sidebar titles and the composer outside the message walk.
        guard let region = conversationRegion(in: window) else {
            recovery.observedContent(available: false)
            var diagnostics = [
                "target=\(Self.bundleIdentifier) version=\(appVersion(app))",
                rendererAccessibilityDiagnostic,
                "window=\(text(window))",
                "Conversation landmark not found. No unscoped text was classified.",
            ]
            if includeDiagnostics {
                diagnostics += detailedDiagnostics(walk(window), window: windowFrame)
            }
            return empty(diagnostics, window: windowFrame, reason: "rendererUnavailable")
        }
        recovery.observedContent(available: true)
        let before = context(app: app, window: window, region: region)
        let walked = walk(region)
        let tokens = walked.nodes.map {
            ModernConversationNode(role: $0.role, text: $0.text, depth: $0.depth,
                subrole: includeResponses && ["AXGroup", "AXList"].contains($0.role) ? (string($0.element, kAXSubroleAttribute) ?? "") : "")
        }
        let prompts = ModernConversationParser.userPrompts(
            in: tokens, includeTrailingMessage: !walked.truncated
        )
        let entries = prompts.compactMap { prompt -> NavigationEntry? in
            guard let first = prompt.sourceIndices.first else { return nil }
            let elements = prompt.sourceIndices.map { walked.nodes[$0].element }
            let rectangles = elements.compactMap(frame)
            let bounds = rectangles.reduce(nil as CGRect?) { result, rect in
                result.map { $0.union(rect) } ?? rect
            }
            return NavigationEntry(
                id: "new-app:\(prompt.turn):\(prompt.text)",
                preview: String(prompt.text.prefix(100)), fullText: prompt.text,
                confidence: .userMessage, sourceRole: "AXHeading[You said:]",
                element: walked.nodes[first].element, frame: bounds, scrollFraction: nil,
                modernSourceID: messageID(startingAt: walked.nodes[prompt.headingIndex].element, region: region)
            )
        }
        var responseTexts: [String: String] = [:]
        if includeResponses && !walked.truncated {
            for (prompt, entry) in zip(prompts, entries) {
                if let response = ModernResponseText.extract(in: tokens, following: prompt) {
                    responseTexts[entry.id] = response
                }
            }
        }
        let viewport = messageViewport(region: region, window: windowFrame)
        let location = includeLocation ? locationEvidence(
            app: app, region: region, viewport: viewport, nodes: walked.nodes,
            tokens: tokens, prompts: prompts
        ) : nil
        let indexEvidence = includeIndexing ? indexingEvidence(
            nodes: walked.nodes, prompts: prompts, viewport: viewport,
            region: region, truncated: walked.truncated
        ) : nil
        if indexEvidence?.isBusy == true { responseTexts.removeAll() }
        let scrollPoint = includeIndexing ? indexingPoint(region: region, viewport: viewport, pid: app.processIdentifier) : nil
        let after = context(app: app, window: window, region: region)
        guard before == after else {
            return empty(["Conversation changed during the scan; waiting for the next snapshot."], window: windowFrame, reason: "conversationChanged")
        }
        let headingCount = tokens.filter {
            $0.role == "AXHeading" && ModernConversationParser.speaker($0.text) != nil
        }.count
        var diagnostics = [
            "mode=navigator-24-renderer-recovery baseline=0.7.1",
            "target=\(Self.bundleIdentifier) version=\(appVersion(app))",
            rendererAccessibilityDiagnostic,
            "window=\(text(window))",
            "scope=Conversation nodes=\(walked.nodes.count) truncated=\(walked.truncated)",
            "speaker-headings=\(headingCount) user-prompts=\(entries.count)",
            "identity=\(before.conversationID == nil ? "window-title-and-region" : "conversation-route") title=\(before.title)",
            "conversation-route=\(before.conversationID ?? "unavailable") window=\(before.windowID) region=\(before.regionID)",
            "native-message-ids=\(entries.filter { $0.modernSourceID != nil }.count)",
            "location-anchor=\(String(describing: location?.anchor)) frame-estimate=\(location?.allowsFrameEstimate ?? false)",
            "location-viewport=\(String(describing: location?.viewport))",
            "index-sample=\(String(describing: indexEvidence)) scroll-point=\(String(describing: scrollPoint))",
            "The following labels are included only when you explicitly save a snapshot.",
        ]
        diagnostics += walked.nodes.filter { !$0.text.isEmpty }.prefix(240).map {
            "depth=\($0.depth) role=\($0.role) text=\(String($0.text.prefix(180)))"
        }
        if includeDiagnostics {
            diagnostics += detailedDiagnostics(walked, window: windowFrame)
            if context(app: app, window: window, region: region) != before {
                diagnostics.append("WARNING: Conversation changed during detailed capture. Repeat the snapshot in the intended chat.")
            }
        }
        return ConversationSnapshot(
            entries: entries, chatWindowFrame: windowFrame,
            usedStructuralOwnership: !entries.isEmpty, diagnosticLines: diagnostics,
            viewportFrame: viewport, scrollFraction: nil, modernContext: before,
            modernLocationEvidence: location, modernIndexEvidence: indexEvidence, modernScrollPoint: scrollPoint, modernResponseTexts: responseTexts
        )
    }

    /// Explicit diagnostics only. Reads structure and geometry without copying or clicking.
    private func detailedDiagnostics(_ walk: Walk, window: CGRect?) -> [String] {
        let nodes = Array(walk.nodes.prefix(3_000))
        let references = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { (CFHash($0.element.element), $0.offset) })
        func json(_ object: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]),
                  let value = String(data: data, encoding: .utf8) else { return "{\"serializationFailed\":true}" }
            return value
        }
        func rect(_ value: CGRect) -> [String: Double] {
            guard !value.isNull, !value.isInfinite,
                  [value.minX, value.minY, value.width, value.height].allSatisfy({ $0.isFinite }) else { return [:] }
            return ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        func encoded(_ value: CFTypeRef, level: Int = 0) -> Any {
            if CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = unsafeDowncast(value, to: AXUIElement.self)
                return ["nodeRef": references[CFHash(element)] ?? -1]
            }
            if let attributed = value as? NSAttributedString { return String(attributed.string.prefix(65_536)) }
            if let text = value as? String { return String(text.prefix(65_536)) }
            if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : number.stringValue as Any }
            if let dictionary = value as? [String: Any], level < 3 {
                return dictionary.mapValues { encoded($0 as CFTypeRef, level: level + 1) }
            }
            if let values = value as? [Any], level < 3 {
                return values.prefix(100).map { encoded($0 as CFTypeRef, level: level + 1) }
            }
            return String(describing: value).prefix(2_048).description
        }
        var lines = [
            "detailed-schema=1 format=JSON-lines",
            "detailed-nodes=\(nodes.count) total-walk-nodes=\(walk.nodes.count) diagnostic-cap=3000 diagnostic-truncated=\(walk.nodes.count > nodes.count || walk.truncated)",
            "detailed-text-limit-per-attribute=65536",
            "frontmost-bundle=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")",
            "Detailed records include local conversation text and math metadata. No Copy action or mouse click is performed.",
        ]
        var ancestors: [Int] = []
        for (index, node) in nodes.enumerated() {
            guard mayRead else { break }
            while let last = ancestors.last, nodes[last].depth >= node.depth { ancestors.removeLast() }
            var record: [String: Any] = ["node": index, "depth": node.depth, "role": node.role, "parent": ancestors.last ?? -1]
            ancestors.append(index)
            if let bounds = frame(node.element) { record["frame"] = rect(bounds) }
            guard prepare(node.element) else { break }
            var names: CFArray?
            self.record(AXUIElementCopyAttributeNames(node.element, &names))
            let available = names as? [String] ?? []
            record["attributeNames"] = available.sorted()
            var childCounts: [String: Int] = [:]
            for key in [kAXChildrenAttribute, "AXVisibleChildren", "AXContents", "AXChildrenInNavigationOrder"] {
                if let values: [AXUIElement] = attribute(node.element, key) { childCounts[key] = values.count }
            }
            record["childCounts"] = childCounts
            var attributes: [String: Any] = [:]
            let keys = Set(["AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue", "AXHelp", "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXDOMTag", "AXAttributedValue"] + available.filter {
                let name = $0.lowercased()
                return name.contains("math") || name.contains("latex") || name.contains("texsource")
            })
            for key in keys.sorted() {
                guard prepare(node.element) else { break }
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(node.element, key as CFString, &value)
                self.record(error)
                if error == .success, let value { attributes[key] = encoded(value) }
            }
            record["attributes"] = attributes
            guard prepare(node.element) else { break }
            var actions: CFArray?
            self.record(AXUIElementCopyActionNames(node.element, &actions))
            record["actions"] = actions as? [String] ?? []
            if node.role == "AXButton", let bounds = frame(node.element),
               let window, let point = ModernResponseCapturePolicy.clickPoint(button: bounds, window: window) {
                var hit: AXUIElement?
                if hitTest(point, result: &hit), let hit {
                    var pid: pid_t = 0
                    _ = AXUIElementGetPid(hit, &pid)
                    record["centerHit"] = ["pid": pid, "role": string(hit, kAXRoleAttribute) ?? "", "nodeRef": references[CFHash(hit)] ?? -1] as [String: Any]
                    var current: AXUIElement? = hit
                    var matches = false
                    for _ in 0..<6 {
                        guard let element = current else { break }
                        if CFEqual(element, node.element) { matches = true; break }
                        current = attribute(element, kAXParentAttribute)
                    }
                    record["centerHitMatchesButton"] = matches
                }
            }
            lines.append(json(record))
        }
        return lines
    }

    private func indexingEvidence(nodes: [Node], prompts: [ModernUserPrompt], viewport: CGRect?,
                                  region: AXUIElement, truncated: Bool) -> ModernIndexEvidence {
        var leading = Hasher()
        var leadingCount = 0
        // User text is stable while the assistant streams. If the current loaded
        // window has only a response, its leading text still distinguishes it
        // from another response section without hashing an elapsed-time label.
        for prompt in prompts.prefix(3) {
            leading.combine(ModernNavigationPolicy.canonical(prompt.text)); leadingCount += 1
        }
        if leadingCount == 0 {
            for node in nodes.filter({ $0.role == "AXStaticText" && !$0.text.isEmpty }).prefix(3) {
                leading.combine(String(node.text.prefix(120))); leadingCount += 1
            }
        }
        var visible = Hasher()
        var visibleCount = 0
        var busy = (attribute(region, kAXElementBusyAttribute) as NSNumber?)?.boolValue ?? false
        for node in nodes where ["AXProgressIndicator", "AXBusyIndicator"].contains(node.role) {
            if let viewport, let bounds = frame(node.element), bounds.intersects(viewport) { busy = true }
        }
        for node in nodes.filter({ $0.role == "AXStaticText" && !$0.text.isEmpty }).prefix(300) {
            guard let viewport, let bounds = frame(node.element), bounds.intersects(viewport),
                  bounds.minY.isFinite else { continue }
            visible.combine(String(node.text.prefix(120)))
            visible.combine(Int(min(1_000_000, max(-1_000_000, bounds.minY - viewport.minY)) / 12))
            visibleCount += 1
        }
        var fraction: Double?
        var current: AXUIElement? = region
        for _ in 0..<depthLimit {
            guard let element = current else { break }
            if let bar: AXUIElement = attribute(element, "AXVerticalScrollBar"),
               let value: NSNumber = attribute(bar, kAXValueAttribute) {
                fraction = value.doubleValue; break
            }
            current = attribute(element, kAXParentAttribute)
        }
        return ModernIndexEvidence(leadingFingerprint: leadingCount > 0 ? leading.finalize() : nil,
                                   visibleFingerprint: visibleCount > 0 ? visible.finalize() : nil,
                                   isBusy: busy, isTruncated: truncated, scrollFraction: fraction)
    }

    private func indexingPoint(region: AXUIElement, viewport: CGRect?, pid: pid_t) -> CGPoint? {
        guard var viewport, !viewport.isNull, !viewport.isEmpty else { return nil }
        if let bounds = frame(region), !bounds.isEmpty {
            let clipped = viewport.intersection(bounds)
            if !clipped.isNull, !clipped.isEmpty { viewport = clipped }
        }
        guard viewport.minX.isFinite, viewport.midY.isFinite, viewport.width.isFinite else { return nil }
        for fraction: CGFloat in [0.12, 0.88, 0.5, 0.65, 0.35] {
            let point = CGPoint(x: viewport.minX + viewport.width * fraction, y: viewport.midY)
            var hit: AXUIElement?
            guard hitTest(point, result: &hit),
                  let hit else { continue }
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else { continue }
            var current: AXUIElement? = hit
            var seen = Set<CFHashCode>()
            for _ in 0..<depthLimit {
                guard let element = current, seen.insert(CFHash(element)).inserted else { break }
                if CFEqual(element, region) { return point }
                let role: String = attribute(element, kAXRoleAttribute) ?? ""
                if ["AXTextArea", "AXTextField", "AXComboBox", "AXScrollArea"].contains(role) { break }
                current = attribute(element, kAXParentAttribute)
            }
        }
        return nil
    }

    private func locationEvidence(app: NSRunningApplication, region: AXUIElement,
                                  viewport: CGRect?, nodes: [Node],
                                  tokens: [ModernConversationNode],
                                  prompts: [ModernUserPrompt]) -> ModernLocationEvidence? {
        guard var viewport, !viewport.isNull, !viewport.isEmpty else { return nil }
        if let bounds = frame(region), !bounds.isNull, !bounds.isEmpty {
            let clipped = viewport.intersection(bounds)
            if !clipped.isNull, !clipped.isEmpty { viewport = clipped }
        }
        let lookup = Dictionary(grouping: nodes.indices, by: { CFHash(nodes[$0].element) })
        var sawAppContent = false
        // Same vertical midpoint, several horizontal points: whitespace often
        // exposes a broad container instead of the message beneath the center.
        for fraction: CGFloat in [0.5, 0.65, 0.35] {
            var hit: AXUIElement?
            guard hitTest(CGPoint(x: viewport.minX + viewport.width * fraction, y: viewport.midY), result: &hit), let hit else { continue }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success, pid == app.processIdentifier else { continue }
            var current: AXUIElement? = hit
            var seen = Set<CFHashCode>()
            for _ in 0..<depthLimit {
                guard let element = current, seen.insert(CFHash(element)).inserted else { break }
                if let index = lookup[CFHash(element)]?.first(where: { CFEqual(nodes[$0].element, element) }) {
                    sawAppContent = true
                    if let anchor = ModernConversationLocation.anchor(at: index, nodes: tokens, prompts: prompts) {
                        return ModernLocationEvidence(anchor: anchor, viewport: viewport, allowsFrameEstimate: false)
                    }
                    break
                }
                current = attribute(element, kAXParentAttribute)
            }
        }
        // Do not keep a marker based on stale coordinates when a different
        // window/app covers the sampled portion of the conversation.
        return ModernLocationEvidence(anchor: nil, viewport: viewport, allowsFrameEstimate: sawAppContent)
    }

    private func messageViewport(region: AXUIElement, window: CGRect?) -> CGRect? {
        var current: AXUIElement? = region
        var seen = Set<CFHashCode>()
        for _ in 0..<depthLimit {
            guard let element = current, seen.insert(CFHash(element)).inserted else { break }
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if role == "AXScrollArea", let bounds = frame(element) {
                return window.map { bounds.intersection($0) } ?? bounds
            }
            if role == "AXWindow" { break }
            current = attribute(element, kAXParentAttribute)
        }
        // Keep title/toolbar and composer out of a window-only fallback.
        return window.map { $0.insetBy(dx: 12, dy: min(100, $0.height / 4)) }
    }

    private func context(app: NSRunningApplication, window: AXUIElement, region: AXUIElement) -> ModernConversationContext {
        var identity: String?
        var current: AXUIElement? = region
        var visited = Set<CFHashCode>()
        for _ in 0..<depthLimit {
            guard let element = current, visited.insert(CFHash(element)).inserted else { break }
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if !role.isEmpty {
                for key in ["AXURL", kAXDocumentAttribute] {
                    let value: Any? = attribute(element, key)
                    let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                    if let url, let id = ModernConversationContext.conversationID(from: url) {
                        identity = id
                        break
                    }
                }
            }
            if identity != nil || CFEqual(element, window) { break }
            current = attribute(element, kAXParentAttribute)
        }
        return ModernConversationContext(
            processID: app.processIdentifier,
            windowID: String(CFHash(window)), regionID: String(CFHash(region)),
            title: text(window), conversationID: identity
        )
    }

    private func messageID(startingAt heading: AXUIElement, region: AXUIElement) -> String? {
        var current: AXUIElement? = heading
        var visited = Set<CFHashCode>()
        for _ in 0..<7 {
            guard let element = current, !CFEqual(element, region),
                  visited.insert(CFHash(element)).inserted else { break }
            for key in ["AXDOMIdentifier", kAXIdentifierAttribute] {
                if let value = string(element, key), let id = ModernConversationContext.messageID(from: value) { return id }
            }
            current = attribute(element, kAXParentAttribute)
        }
        return nil
    }

    private func empty(_ lines: [String], window: CGRect? = nil, reason: String = "windowUnavailable") -> ConversationSnapshot {
        ConversationSnapshot(entries: [], chatWindowFrame: window,
                             usedStructuralOwnership: false, diagnosticLines: lines, modernScanFailure: reason)
    }

    private func conversationRegion(in root: AXUIElement) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var seen = Set<CFHashCode>()
        var count = 0
        while let (element, depth) = stack.popLast() {
            guard mayRead else { break }
            guard depth <= depthLimit, count < nodeLimit,
                  seen.insert(CFHash(element)).inserted else { continue }
            count += 1
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if ["AXGroup", "AXLandmarkRegion", "AXRegion"].contains(role) {
                let values = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute),
                              string(element, kAXValueAttribute)]
                if values.contains(where: {
                    $0?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare("Conversation") == .orderedSame
                }) { return element }
            }
            for child in children(element).reversed() { stack.append((child, depth + 1)) }
        }
        return nil
    }

    private func walk(_ root: AXUIElement) -> Walk {
        var nodes: [Node] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var seen = Set<CFHashCode>()
        var truncated = false
        while let (element, depth) = stack.popLast() {
            guard mayRead else { break }
            guard nodes.count < nodeLimit else { truncated = true; break }
            guard depth <= depthLimit else { truncated = true; continue }
            guard seen.insert(CFHash(element)).inserted else { continue }
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            let value = ModernResponseCapturePolicy.nodeText(role: role) { text(element) }
            nodes.append(Node(element: element, role: role, text: value, depth: depth))
            for child in children(element).reversed() { stack.append((child, depth + 1)) }
        }
        return Walk(nodes: nodes, truncated: truncated)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        // Alternate child arrays are fallbacks, not extra siblings. Combining
        // them can put a speaker heading after its body or duplicate messages.
        for key in [kAXChildrenAttribute, "AXVisibleChildren", "AXContents", "AXChildrenInNavigationOrder"] {
            if let result: [AXUIElement] = attribute(element, key), !result.isEmpty { return result }
        }
        return []
    }

    private func text(_ element: AXUIElement) -> String {
        for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let value = string(element, key),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return ""
    }
    private func string(_ element: AXUIElement, _ key: String) -> String? {
        let value: Any? = attribute(element, key)
        if let plain = value as? String { return plain }
        return (value as? NSAttributedString)?.string
    }
    private func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        record(error)
        guard error == .success else { return nil }
        return value as? T
    }
    private func hitTest(_ point: CGPoint, result: inout AXUIElement?) -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard prepare(system) else { return false }
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &result)
        record(error)
        return error == .success
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private func appVersion(_ app: NSRunningApplication) -> String {
        guard let url = app.bundleURL else { return "unknown" }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
    func probe(cancellation: ModernReadCancellation) -> ModernConversationProbe? {
        self.cancellation = cancellation
        budget = ModernReadBudget(duration: 0.8)
        defer { budget = nil; self.cancellation = nil }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute)
                ?? attribute(application, kAXMainWindowAttribute) else { return .init(context: nil, title: nil) }
        enableRendererAccessibility(for: app, application: application, window: window)
        let title = text(window)
        guard let region = conversationRegion(in: window) else {
            recovery.observedContent(available: false)
            return .init(context: nil, title: title)
        }
        recovery.observedContent(available: true)
        let value = context(app: app, window: window, region: region)
        return .init(context: mayRead ? value : nil, title: title)
    }

    func findField(pid: pid_t, cancellation: ModernReadCancellation) -> ModernFindField? {
        self.cancellation = cancellation
        budget = ModernReadBudget(duration: 0.7)
        defer { budget = nil; self.cancellation = nil }
        let application = AXUIElementCreateApplication(pid)
        guard let element: AXUIElement = attribute(application, kAXFocusedUIElementAttribute) else { return nil }
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        let subrole: String = attribute(element, kAXSubroleAttribute) ?? ""
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                     "AXPlaceholderValue", kAXIdentifierAttribute, "AXDOMIdentifier"]
        let labels: [String] = names.map { attribute(element, $0) ?? "" }
        guard ModernNavigationPolicy.isFindField(role: role, subrole: subrole, labels: labels), mayRead else { return nil }
        let value: String = attribute(element, kAXValueAttribute) ?? ""
        return mayRead ? ModernFindField(element: element, value: value,
            diagnostics: ["find-focus role=\(role) subrole=\(subrole)"] + zip(names, labels).map { "\($0.0)=\($0.1)" }) : nil
    }

    func copyTarget(entry: NavigationEntry, expected: ModernConversationContext,
                    cancellation: ModernReadCancellation) -> ModernCopyTarget? {
        self.cancellation = cancellation
        budget = ModernReadBudget(duration: 2)
        defer { budget = nil; self.cancellation = nil }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first,
              app.processIdentifier == expected.processID else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute),
              let region = conversationRegion(in: window),
              context(app: app, window: window, region: region).sessionKey == expected.sessionKey,
              var view = messageViewport(region: region, window: frame(window)) else { return nil }
        let walked = walk(region)
        guard !walked.truncated, mayRead else { return nil }
        let tokens = walked.nodes.map { ModernConversationNode(role: $0.role, text: $0.text, depth: $0.depth) }
        let prompts = ModernConversationParser.userPrompts(in: tokens)
        guard !indexingEvidence(nodes: walked.nodes, prompts: prompts, viewport: view,
                                region: region, truncated: walked.truncated).isBusy else { return nil }
        let matches = prompts.filter {
            $0.text == entry.fullText && (entry.modernSourceID == nil || messageID(startingAt: walked.nodes[$0.headingIndex].element, region: region) == entry.modernSourceID)
        }
        guard matches.count == 1, let prompt = matches.first,
              let range = ModernResponseCapturePolicy.responseRange(in: tokens, following: prompt.headingIndex) else { return nil }
        let buttons = ModernResponseCapturePolicy.footerButtons(in: tokens, range: range)
        guard buttons.count == 1, let index = buttons.first,
              let bounds = frame(walked.nodes[index].element) else { return nil }
        if let field = walked.nodes.firstIndex(where: { $0.role == "AXTextArea" }),
           let container = (0..<field).reversed().first(where: { walked.nodes[$0].depth == 1 }),
           let composer = frame(walked.nodes[container].element), composer.minY > view.minY + 100,
           composer.height < view.height / 2, composer.minY < view.maxY {
            view.size.height = max(0, composer.minY - 4 - view.minY)
        }
        guard mayRead, context(app: app, window: window, region: region).sessionKey == expected.sessionKey, mayRead else { return nil }
        return ModernCopyTarget(button: walked.nodes[index].element,
            nextPrompt: range.upperBound < walked.nodes.count ? walked.nodes[range.upperBound].element : nil,
            viewport: view, bounds: bounds)
    }

}
