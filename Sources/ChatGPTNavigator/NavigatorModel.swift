import AppKit
import Combine
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@MainActor
final class NavigatorModel: ObservableObject {
    @Published private(set) var entries: [NavigationEntry] = []
    @Published private(set) var state: NavigatorState = .needsPermission
    @Published private(set) var usesStructuralOwnership = false
    @Published private(set) var chatWindowFrame: CGRect?
    @Published private(set) var isIndexing = false
    @Published private(set) var indexingProgress: Double = 0
    @Published private(set) var indexingStatus = "Indexing upward…"
    @Published private(set) var isResponseExportMode = false
    @Published private(set) var selectedResponseIDs: Set<String> = []
    @Published private(set) var isExportingResponses = false
    @Published private(set) var responseExportProgress: Double = 0
    @Published private(set) var responseExportStatus = ""
    @Published var showsCapturedResponse = false
    @Published private(set) var capturedClipboardFormats = ""
    @Published private(set) var clipboardCapture: ResponseClipboardPacket?
    @Published private(set) var capturedResponseText = ""
    private var downloadOperationID: UUID?
    private var directResponseCache: [String: String] = [:]
    private var verifiedResponse: (entryID: String, sessionKey: String, response: String)?
    @Published var responseExportFormat: ResponseExportFormat = .markdown
    @Published var searchText = ""
    @Published var navigationMessage: String?
    @Published private(set) var selectedPromptID: String?
    @Published private(set) var conversationLocation = ConversationLocation()
    @Published private(set) var orderIsProvisional = false
    @Published private(set) var pendingOrderGroupStarts: Set<String> = []
    @Published private(set) var modernLoadedCount = 0
    @Published private(set) var modernConversationTitle: String?
    @Published private(set) var modernUsesTitleIdentity = false
    @Published private(set) var modernMemoryWarning: String?

    private let accessibility = AccessibilityClient()
    private let modernAccessibility: ModernAccessibilityClient
    private let modernTrustCheck: () -> Bool
    @Published private(set) var modernConnectionReady = false
    private var modernRefreshTask: Task<Void, Never>?
    private var modernRefreshID: UUID?
    private var modernNavigationID: UUID?
    private var modernIndexID: UUID?

    private var modernMemory = ModernPromptMemory()
    private var refreshTimer: Timer?
    private var lastAutomaticRefresh = Date.distantPast
    private var entriesByID: [String: NavigationEntry] = [:]
    private var promptOrder = PromptOrder()
    private var locationTracker = ConversationLocationTracker()
    private var selectedConversation: ConversationIdentity?
    private var conversationGeneration = 0
    private var indexingTask: Task<Void, Never>?
    private var activeIndexSession: ConversationScrollSession?
    private var activeIndexIdentity: ConversationIdentity?
    private var activePhysicalIndexInput: PhysicalIndexScrollSession?
    private var responseExportTask: Task<Void, Never>?
    @Published private(set) var isNavigating = false
    private var modernNavigationTask: Task<Void, Never>?
    private var modernIndexTask: Task<Void, Never>?
    private lazy var modernIndexer = ModernBatchIndexer(client: modernAccessibility)
    private var modernNavigator: ModernFindNavigator?

    init(modernAccessibility: ModernAccessibilityClient = ModernAccessibilityClient(),
         modernTrustCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.modernAccessibility = modernAccessibility
        self.modernTrustCheck = modernTrustCheck
    }

    var filteredEntries: [NavigationEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
            $0.preview.localizedCaseInsensitiveContains(searchText)
        }
    }

    var permissionGranted: Bool {
        state != .needsPermission
    }

    var locationText: String {
        if NewAppPreview.enabled {
            if isIndexing { return "Location tracking paused while indexing" }
            if isNavigating { return "Location tracking paused while navigating" }
            return conversationLocation.label(in: entries.map(\.id), numbersAreProvisional: orderIsProvisional)
        }
        if isIndexing {
            return "Location tracking paused while indexing"
        }
        if isExportingResponses {
            return "Location tracking paused while exporting"
        }
        return conversationLocation.label(in: promptOrder.ids)
    }

    var footerText: String {
        if NewAppPreview.enabled {
            if isIndexing { return "\(indexingStatus) · \(entries.count) prompts remembered" }
            if entries.isEmpty { return state.message }
            if modernMemory.context == nil { return "\(entries.count) prompts · memory unavailable" }
            return "\(entries.count) remembered"
        }
        if isIndexing {
            return "\(indexingStatus) · \(entries.count) prompts remembered"
        }
        if isExportingResponses {
            return responseExportStatus
        }
        if isResponseExportMode {
            let count = selectedResponseIDs.count
            return "\(count) response\(count == 1 ? "" : "s") selected for export"
        }
        if usesStructuralOwnership, !entries.isEmpty {
            return "\(entries.count) remembered user prompt\(entries.count == 1 ? "" : "s")"
        }
        switch entries.count {
        case 0:
            return state.message
        case 1:
            return "1 navigation item"
        default:
            return "\(entries.count) navigation items"
        }
    }

    func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: NewAppPreview.enabled ? 1.2 : 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.automaticRefresh()
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        modernRefreshTask?.cancel()
        modernRefreshTask = nil
        modernRefreshID = nil
        cancelModernOperations()
        cancelIndexingAndRestoreScroll()
        responseExportTask?.cancel()
        responseExportTask = nil
    }

    func requestPermission() {
        _ = accessibility.requestTrustPrompt()
        navigationMessage = "After enabling access in System Settings, return here. Visible prompts refresh automatically."
        refresh()
    }

    func refresh() {
        navigationMessage = nil

        _ = observeSelectedConversation()

        refreshCurrentConversation(writeDiagnostics: !NewAppPreview.enabled)
    }

    private func refreshCurrentConversation(writeDiagnostics: Bool) {
        if NewAppPreview.enabled {
            refreshModernPreview(writeDiagnostics: writeDiagnostics)
            return
        }
        let identityBeforeScan = selectedConversation

        guard accessibility.isTrusted else {
            state = .needsPermission
            clearRegistry()
            usesStructuralOwnership = false
            chatWindowFrame = nil
            return
        }

        guard accessibility.runningClassicApplication() != nil else {
            state = .chatGPTNotRunning
            clearRegistry()
            usesStructuralOwnership = false
            chatWindowFrame = nil
            return
        }

        guard let snapshot = accessibility.scan() else {
            state = .chatGPTNotRunning
            clearRegistry()
            usesStructuralOwnership = false
            chatWindowFrame = nil
            return
        }

        if observeSelectedConversation() || selectedConversation != identityBeforeScan {
            // The selection changed while Accessibility was walking the old
            // hierarchy. Discard that snapshot so messages can never cross
            // conversation boundaries, then scan the new selection once.
            let retryIdentity = selectedConversation
            guard let retrySnapshot = accessibility.scan(),
                  !observeSelectedConversation(),
                  selectedConversation == retryIdentity else {
                return
            }
            merge(retrySnapshot)
            lastAutomaticRefresh = Date()
            if writeDiagnostics {
                DiagnosticLog.write(
                    lines: retrySnapshot.diagnosticLines,
                    windowFrame: retrySnapshot.chatWindowFrame
                )
            }
            return
        }

        merge(snapshot)
        lastAutomaticRefresh = Date()

        if writeDiagnostics {
            DiagnosticLog.write(
                lines: snapshot.diagnosticLines,
                windowFrame: snapshot.chatWindowFrame
            )
        }
    }

    func navigate(to entry: NavigationEntry) {
        if NewAppPreview.enabled {
            navigateModern(to: entry)
            return
        }
        guard !isIndexing, !isExportingResponses else {
            navigationMessage = isIndexing
                ? "Wait for indexing to finish before navigating."
                : "Wait for response export to finish before navigating."
            return
        }
        guard !isNavigating else { return }
        selectedPromptID = entry.id
        isNavigating = true
        navigationMessage = "Finding the selected prompt in ChatGPT Classic…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isNavigating = false }
            self.navigationMessage = await self.accessibility.navigateUsingFind(
                to: entry.fullText
            )
        }
    }

    private func navigateModern(to entry: NavigationEntry) {
        guard !isNavigating, !isIndexing, !isExportingResponses else {
            navigationMessage = "Stop the current operation before choosing another prompt."
            return
        }
        guard modernConnectionReady, let context = modernMemory.context, context.sessionKey != nil else {
            navigationMessage = "Reconnecting to the current conversation…"
            refreshModernPreview(writeDiagnostics: false)
            return
        }
        let operation = UUID()
        let generation = conversationGeneration
        modernNavigationID = operation
        let navigator = ModernFindNavigator(client: modernAccessibility)
        modernNavigator = navigator
        selectedPromptID = entry.id
        isNavigating = true
        navigationMessage = "Finding the selected prompt in ChatGPT…"
        conversationLocation = ConversationLocation()
        modernNavigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await navigator.navigate(to: entry, context: context, continueWhile: { [weak self] in
                self?.modernNavigationID == operation && self?.conversationGeneration == generation
            })
            guard self.modernNavigationID == operation, !Task.isCancelled else { return }
            self.isNavigating = false
            self.modernNavigationID = nil
            self.modernNavigationTask = nil
            self.navigationMessage = result
            self.refreshModernPreview(writeDiagnostics: false)
        }
    }

    func stopModernNavigation() {
        modernNavigationID = nil
        modernNavigationTask?.cancel()
        modernNavigationTask = nil
        isNavigating = false
        navigationMessage = "Navigation stopped."
        refreshModernPreview(writeDiagnostics: false)
    }

    private func cancelModernOperations() {
        conversationGeneration += 1
        modernNavigationID = nil
        modernIndexID = nil
        downloadOperationID = nil
        modernNavigationTask?.cancel()
        modernIndexTask?.cancel()
        responseExportTask?.cancel()
        modernNavigationTask = nil
        modernIndexTask = nil
        responseExportTask = nil
        isNavigating = false
        isIndexing = false
        isExportingResponses = false
        responseExportStatus = ""
    }

    func reconnectModernConversation() {
        cancelModernOperations()
        modernRefreshTask?.cancel()
        modernRefreshTask = nil
        modernRefreshID = nil
        clearRegistry()
        state = .reconnecting
        navigationMessage = "Reconnecting to ChatGPT…"
        Task { [weak self] in
            guard let self else { return }
            await self.modernAccessibility.worker.requestRecovery()
            self.refreshModernPreview(writeDiagnostics: false)
        }
    }

    func toggleResponseExportMode() {
        guard !isIndexing, !isExportingResponses else { return }
        verifiedResponse = nil
        clipboardCapture = nil
        isResponseExportMode.toggle()
        selectedResponseIDs.removeAll()
        navigationMessage = isResponseExportMode
            ? "Select the prompts whose responses you want to save."
            : nil
    }

    func toggleResponseSelection(for entry: NavigationEntry) {
        guard isResponseExportMode, !isExportingResponses else { return }
        verifiedResponse = nil
        clipboardCapture = nil
        if selectedResponseIDs.contains(entry.id) {
            selectedResponseIDs.remove(entry.id)
        } else {
            selectedResponseIDs.insert(entry.id)
        }
    }

    func downloadSelectedReply() {
        guard isResponseExportMode, !isIndexing, !isNavigating, !isExportingResponses,
              !selectedResponseIDs.isEmpty,
              modernConnectionReady, let context = modernMemory.context, context.sessionKey != nil else { return }
        let selectedEntries = entries.filter { selectedResponseIDs.contains($0.id) }
        guard !selectedEntries.isEmpty else { return }
        let count = selectedEntries.count
        let format = responseExportFormat
        let panel = NSSavePanel()
        panel.title = count == 1 ? "Save ChatGPT reply" : "Save ChatGPT replies"
        panel.nameFieldStringValue = ResponseExportDocument.defaultFilename(for: format)
        panel.allowedContentTypes = [UTType(filenameExtension: format.filenameExtension) ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let operation = UUID()
        downloadOperationID = operation
        isExportingResponses = true
        responseExportProgress = 0
        responseExportStatus = "Copying selected reply… Keep the pointer still."
        navigationMessage = nil
        responseExportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.downloadOperationID == operation {
                    self.isExportingResponses = false
                    self.responseExportStatus = ""
                    self.responseExportTask = nil
                    self.downloadOperationID = nil
                }
            }
            do {
                try await ResponseDownloadPipeline.runBatch(prompts: selectedEntries.map(\.fullText), copy: { index in
                    guard self.downloadOperationID == operation, !Task.isCancelled else { return nil }
                    self.responseExportStatus = "Copying reply \(index + 1) of \(count)… Keep the pointer still."
                    self.responseExportProgress = 0.8 * Double(index) / Double(count)
                    let packet = await self.modernAccessibility.copyResponseWithNativeButton(following: selectedEntries[index], context: context)
                    return packet?.plainText
                }, write: { items in
                    self.responseExportStatus = "Saving \(items.count) repl\(items.count == 1 ? "y" : "ies") as \(format.label)…"
                    self.responseExportProgress = 0.8
                    try await MathResponseExporter.write(items: items, to: destination, format: format)
                })
                guard self.downloadOperationID == operation else { return }
                self.responseExportProgress = 1
                self.navigationMessage = "Saved \(count) repl\(count == 1 ? "y" : "ies") to \(destination.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                // The Stop action owns the cancellation status.
            } catch {
                guard self.downloadOperationID == operation else { return }
                let detail = error is ResponseDownloadPipeline.Failure
                    ? error.localizedDescription + " " + self.modernAccessibility.lastCaptureFailure
                    : error.localizedDescription
                self.navigationMessage = "Download failed: \(detail.isEmpty ? error.localizedDescription : detail)"
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func exportSelectedResponses() {
        guard isResponseExportMode,
              !isIndexing,
              !isNavigating,
              !isExportingResponses else { return }

        if observeSelectedConversation() {
            refreshCurrentConversation(writeDiagnostics: false)
            navigationMessage = "The conversation changed. Select responses from the new conversation."
            return
        }

        let selectedEntries = entries.filter { selectedResponseIDs.contains($0.id) }
        guard !selectedEntries.isEmpty else {
            navigationMessage = "Select at least one prompt before continuing."
            return
        }

        let intendedGeneration = conversationGeneration
        let intendedIdentity = selectedConversation
        let format = responseExportFormat
        let savePanel = NSSavePanel()
        savePanel.title = "Save ChatGPT Responses"
        savePanel.nameFieldStringValue = ResponseExportDocument.defaultFilename(
            for: format
        )
        savePanel.allowedContentTypes = [
            UTType(filenameExtension: format.filenameExtension) ?? .data,
        ]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        NSApp.activate(ignoringOtherApps: true)
        guard savePanel.runModal() == .OK, let destination = savePanel.url else {
            return
        }

        if (NewAppPreview.enabled && !modernConnectionReady) || observeSelectedConversation() ||
            conversationGeneration != intendedGeneration ||
            selectedConversation != intendedIdentity {
            refreshCurrentConversation(writeDiagnostics: false)
            navigationMessage = "The conversation changed before export began. Select responses again."
            return
        }

        let modernContext = modernMemory.context
        let exportGeneration = conversationGeneration
        let exportIdentity = selectedConversation
        isExportingResponses = true
        responseExportProgress = 0
        responseExportStatus = "Preparing response export…"
        navigationMessage = nil

        responseExportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var exportedItems: [ResponseExportItem] = []

            for (offset, entry) in selectedEntries.enumerated() {
                guard await self.responseExportPassIsCurrent(
                    generation: exportGeneration,
                    identity: exportIdentity
                ) else { return }

                self.responseExportStatus = "Reading response \(offset + 1) of \(selectedEntries.count)…"
                var response: String?
                var failure = "The response could not be copied."
                if NewAppPreview.enabled, let context = modernContext {
                    if let verified = self.verifiedResponse, verified.entryID == entry.id, verified.sessionKey == context.sessionKey {
                        response = verified.response
                    } else {
                        response = await self.modernAccessibility.captureResponse(following: entry, context: context)
                        if response == nil { response = self.directResponseCache[entry.id] }
                    }
                    failure = self.modernAccessibility.lastCaptureFailure
                } else if !NewAppPreview.enabled {
                    _ = await self.accessibility.navigateUsingFind(to: entry.fullText)
                    response = await self.accessibility.captureResponse(following: entry.fullText)
                }
                guard await self.responseExportPassIsCurrent(generation: exportGeneration, identity: exportIdentity) else { return }
                let responseText: String
                if let response, !response.isEmpty {
                    responseText = response
                } else {
                    self.isExportingResponses = false
                    self.responseExportTask = nil
                    self.responseExportStatus = ""
                    self.navigationMessage = "Download stopped: \(failure) No file was saved."
                    return
                }
                exportedItems.append(
                    ResponseExportItem(prompt: entry.fullText, response: responseText)
                )
                self.responseExportProgress = Double(offset + 1) / Double(selectedEntries.count)
            }

            guard await self.responseExportPassIsCurrent(
                generation: exportGeneration,
                identity: exportIdentity
            ) else { return }

            do {
                try await MathResponseExporter.write(
                    items: exportedItems,
                    to: destination,
                    format: format
                )
                self.isExportingResponses = false
                self.isResponseExportMode = false
                self.selectedResponseIDs.removeAll()
                self.responseExportTask = nil
                self.responseExportStatus = ""
                self.navigationMessage = "Saved \(exportedItems.count) response\(exportedItems.count == 1 ? "" : "s") to \(destination.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self.isExportingResponses = false
                self.responseExportTask = nil
                self.responseExportStatus = ""
                self.navigationMessage = "Could not save the document: \(error.localizedDescription)"
            }
        }
    }

    func cancelResponseExport() {
        downloadOperationID = nil
        verifiedResponse = nil
        capturedResponseText = ""
        showsCapturedResponse = false
        guard isResponseExportMode || isExportingResponses else { return }
        responseExportTask?.cancel()
        responseExportTask = nil
        isExportingResponses = false
        isResponseExportMode = false
        selectedResponseIDs.removeAll()
        responseExportProgress = 0
        responseExportStatus = ""
        navigationMessage = "Response export cancelled."
    }

    func indexEntireConversation() {
        if NewAppPreview.enabled { startModernIndex(); return }
        guard !isIndexing, !isNavigating, !isResponseExportMode,
              !isExportingResponses, accessibility.isTrusted else { return }
        _ = observeSelectedConversation()
        guard let session = accessibility.beginConversationScrollSession() else {
            navigationMessage = "The conversation scrollbar was not accessible."
            return
        }

        isIndexing = true
        indexingProgress = 0
        indexingStatus = "Indexing upward…"
        navigationMessage = nil
        activeIndexSession = session
        activeIndexIdentity = selectedConversation

        let indexGeneration = conversationGeneration
        let indexedConversation = selectedConversation

        indexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let input = await self.accessibility.beginPhysicalIndexScroll(in: session) else {
                guard !Task.isCancelled else { return }
                self.cancelIndexingAndRestoreScroll()
                self.navigationMessage = IndexPaginationPolicy.StopReason.inputUnavailable.message
                return
            }
            self.activePhysicalIndexInput = input
            defer { self.accessibility.endPhysicalIndexScroll(input) }
            var currentSession = session
            var policy = IndexPaginationPolicy()
            var automaticOrder = AutomaticIndexOrder()
            var stopReason = IndexPaginationPolicy.StopReason.timeLimit
            let startedAt = ProcessInfo.processInfo.systemUptime
            let startingFraction = max(0.000_001, session.originalFraction)

            while true {
                guard await self.indexPassIsCurrent(
                    generation: indexGeneration,
                    identity: indexedConversation
                ) else { return }

                guard self.accessibility.physicalIndexInputIsActive(input) else {
                    stopReason = .inputInterrupted
                    break
                }

                // Refresh after every asynchronous settling wait. A virtualized
                // list may replace either the scroll area or its scrollbar.
                let refreshed = self.accessibility.refreshIndexScrollSession(currentSession)
                var sample: ConversationIndexSample?
                if let refreshed {
                    currentSession = refreshed
                    self.activeIndexSession = refreshed
                    sample = self.accessibility.sampleForIndexing(in: refreshed)
                }
                guard await self.indexPassIsCurrent(
                    generation: indexGeneration,
                    identity: indexedConversation
                ) else { return }
                if let sample {
                    let sampledOrder = PromptOrderEvidence(
                        observations: sample.snapshot.entries.map { (id: $0.id, frame: $0.frame) }
                    ).orderedIDs
                    let passOrder = automaticOrder.observe(sampledOrder)
                    self.merge(sample.snapshot, automaticPassOrder: passOrder)
                    if let fraction = sample.evidence.scrollFraction, fraction.isFinite {
                        // Approximate loaded-range progress, never proof that
                        // the backend has no additional history to fetch.
                        self.indexingProgress = min(0.95, max(
                            self.indexingProgress, max(0, 1 - fraction / startingFraction)
                        ))
                    }
                }
                let decision = policy.observe(
                    sample?.evidence,
                    elapsed: ProcessInfo.processInfo.systemUptime - startedAt
                )
                if case .stop(let reason) = decision {
                    stopReason = reason
                    break
                }
                if decision == .waitForHistory || sample?.evidence.isBusy == true {
                    self.indexingStatus = "Waiting for older history…"
                } else {
                    self.indexingStatus = "Scrolling upward with wheel pulses…"
                }
                if !(await self.accessibility.scrollWheelPulseBurst(input: input)) {
                    stopReason = self.accessibility.physicalIndexInputIsActive(input)
                        ? .inputUnavailable : .inputInterrupted
                    break
                }
                let settleMilliseconds = max(
                    100, policy.delayMilliseconds - AccessibilityClient.indexWheelBurstMilliseconds
                )
                try? await Task.sleep(for: .milliseconds(settleMilliseconds))
            }

            guard await self.indexPassIsCurrent(
                generation: indexGeneration,
                identity: indexedConversation
            ) else { return }
            if stopReason != .inputInterrupted {
                let restoreSession = self.accessibility.refreshIndexScrollSession(currentSession) ?? currentSession
                self.accessibility.restoreScrollPosition(restoreSession)
            }
            self.accessibility.endPhysicalIndexScroll(input)
            self.activePhysicalIndexInput = nil
            self.activeIndexSession = nil
            self.activeIndexIdentity = nil
            try? await Task.sleep(for: .milliseconds(250))
            guard await self.indexPassIsCurrent(
                generation: indexGeneration,
                identity: indexedConversation
            ) else { return }
            self.isIndexing = false
            self.indexingTask = nil
            self.refreshCurrentConversation(writeDiagnostics: false)
            guard self.conversationGeneration == indexGeneration else { return }
            self.navigationMessage = "Remembered \(self.entries.count) user prompts after \(policy.scans) scans upward from your starting position. \(stopReason.message)"
        }
    }

    private func startModernIndex() {
        guard !isIndexing, !isNavigating, !isExportingResponses, accessibility.isTrusted,
              modernConnectionReady, let context = modernMemory.context, context.sessionKey != nil else {
            navigationMessage = "Wait for the current conversation to connect before indexing."
            return
        }
        let operation = UUID()
        let generation = conversationGeneration
        modernIndexID = operation
        isIndexing = true
        indexingStatus = "Preparing full conversation index…"
        navigationMessage = nil
        conversationLocation = ConversationLocation()
        modernIndexTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.modernIndexer.run(context: context,
                capture: { snapshot in
                    guard self.modernIndexID == operation, self.conversationGeneration == generation else { return }
                    self.applyModernSnapshot(snapshot, writeDiagnostics: false)
                }, progress: { value in
                    guard self.modernIndexID == operation else { return }
                    self.indexingStatus = value
                })
            guard self.modernIndexID == operation, !Task.isCancelled else { return }
            self.isIndexing = false
            self.modernIndexID = nil
            self.modernIndexTask = nil
            self.navigationMessage = result
            self.refreshModernPreview(writeDiagnostics: false)
        }
    }

    func cancelIndexing() {
        guard isIndexing else { return }
        if NewAppPreview.enabled {
            modernIndexID = nil
            modernIndexTask?.cancel()
            modernIndexTask = nil
            isIndexing = false
            navigationMessage = "Indexing stopped. Discovered prompts were kept."
            refreshModernPreview(writeDiagnostics: false)
            return
        }
        cancelIndexingAndRestoreScroll()
        navigationMessage = "Indexing stopped. Kept \(entries.count) remembered user prompts."
    }

    func revealAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealDiagnosticLog() {
        guard NewAppPreview.enabled else {
            NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.url])
            return
        }
        guard !isNavigating, !isIndexing, !isExportingResponses else { return }
        navigationMessage = "Saving diagnostics…"
        Task { [weak self] in
            guard let self else { return }
            let trusted = self.accessibility.isTrusted
            let snapshot = trusted ? await self.modernAccessibility.scan(includeLocation: true, includeIndexing: true, includeDiagnostics: true) : nil
            let header = ["diagnostic-build=24", "navigator-path=\(Bundle.main.bundleURL.path)",
                          "accessibility-trusted=\(trusted)", "target-running=\(self.modernAccessibility.isRunning)"]
            let details = snapshot?.diagnosticLines ?? ["No readable target window or Accessibility permission."]
            guard DiagnosticLog.write(lines: header + details + (self.modernNavigator?.focusedFieldDiagnostic() ?? []), windowFrame: snapshot?.chatWindowFrame) else {
                self.navigationMessage = "The diagnostic file could not be written."
                return
            }
            self.navigationMessage = "Saved detailed diagnostics."
            NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.url])
        }
    }

    private func automaticRefresh() {
        if NewAppPreview.enabled {
            refreshCurrentConversation(writeDiagnostics: false)
            return
        }
        if observeSelectedConversation() {
            refreshCurrentConversation(writeDiagnostics: false)
            return
        }
        guard !isIndexing, !isNavigating, !isExportingResponses else { return }
        guard Date().timeIntervalSince(lastAutomaticRefresh) >= 0.55 else { return }
        refreshCurrentConversation(writeDiagnostics: false)
    }

    @discardableResult
    private func observeSelectedConversation() -> Bool {
        guard !NewAppPreview.enabled else { return false }
        guard let current = ConversationIdentity.selectedConversation() else {
            return false
        }

        guard let previous = selectedConversation else {
            selectedConversation = current
            return false
        }
        guard current != previous else { return false }

        selectedConversation = current
        conversationGeneration += 1
        cancelIndexingAndRestoreScroll()
        responseExportTask?.cancel()
        responseExportTask = nil
        isExportingResponses = false
        isResponseExportMode = false
        selectedResponseIDs.removeAll()
        clearRegistry()
        state = .noConversationFound
        navigationMessage = "Conversation changed. Refreshed the visible user messages."
        return true
    }

    private func indexPassIsCurrent(
        generation: Int,
        identity: ConversationIdentity?
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if NewAppPreview.enabled {
            guard let expected = modernMemory.context?.sessionKey,
                  (await modernAccessibility.scan())?.modernContext?.sessionKey == expected else {
                isExportingResponses = false
                responseExportStatus = ""
                navigationMessage = "Download stopped because the conversation changed or became unavailable."
                return false
            }
            return !Task.isCancelled && conversationGeneration == generation
        }
        if observeSelectedConversation() {
            refreshCurrentConversation(writeDiagnostics: false)
            return false
        }
        return conversationGeneration == generation && selectedConversation == identity
    }

    private func responseExportPassIsCurrent(
        generation: Int,
        identity: ConversationIdentity?
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if NewAppPreview.enabled {
            guard let expected = modernMemory.context?.sessionKey,
                  (await modernAccessibility.scan())?.modernContext?.sessionKey == expected else {
                isExportingResponses = false
                responseExportStatus = ""
                navigationMessage = "Download stopped because the conversation changed or became unavailable."
                return false
            }
            return !Task.isCancelled && conversationGeneration == generation
        }
        if observeSelectedConversation() {
            refreshCurrentConversation(writeDiagnostics: false)
            return false
        }
        return conversationGeneration == generation && selectedConversation == identity
    }

    private func cancelIndexingAndRestoreScroll() {
        indexingTask?.cancel()
        indexingTask = nil
        if let input = activePhysicalIndexInput {
            accessibility.endPhysicalIndexScroll(input)
            activePhysicalIndexInput = nil
        }
        if let activeIndexSession {
            // A reused AX element must never restore an old position into a
            // newly selected conversation.
            if ConversationIdentity.selectedConversation() == activeIndexIdentity {
                let session = accessibility.refreshIndexScrollSession(activeIndexSession) ?? activeIndexSession
                accessibility.restoreScrollPosition(session)
            }
            self.activeIndexSession = nil
        }
        activeIndexIdentity = nil
        isIndexing = false
        indexingProgress = 0
    }

    private func refreshModernPreview(writeDiagnostics: Bool) {
        guard modernRefreshTask == nil else { return }
        guard modernTrustCheck() else {
            clearRegistry()
            state = .needsPermission
            chatWindowFrame = nil
            return
        }
        let request = UUID()
        modernRefreshID = request
        let generation = conversationGeneration
        modernRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.modernRefreshID == request {
                    self.modernRefreshTask = nil
                    self.modernRefreshID = nil
                }
            }
            if self.isNavigating || self.isIndexing || self.isExportingResponses {
                let probe = await self.modernAccessibility.probe()
                guard self.modernRefreshID == request, !Task.isCancelled,
                      self.conversationGeneration == generation else { return }
                self.observeModernProbe(probe)
                return
            }
            let snapshot = await self.modernAccessibility.scan(includeLocation: true)
            guard self.modernRefreshID == request, !Task.isCancelled,
                  self.conversationGeneration == generation else { return }
            if self.isNavigating || self.isIndexing || self.isExportingResponses {
                self.observeModernProbe(snapshot.map { .init(context: $0.modernContext, title: $0.modernContext?.title) })
                return
            }
            guard let snapshot else {
                self.clearRegistry()
                self.state = .chatGPTNotRunning
                self.chatWindowFrame = nil
                return
            }
            self.applyModernSnapshot(snapshot, writeDiagnostics: writeDiagnostics)
        }
    }

    private func observeModernProbe(_ probe: ModernConversationProbe?) {
        guard let expected = modernMemory.context else { return }
        guard let actual = probe?.context, actual.sessionKey == expected.sessionKey,
              actual.sessionKey != nil else {
            cancelModernOperations()
            modernConnectionReady = false
            directResponseCache.removeAll()
            verifiedResponse = nil
            selectedResponseIDs.removeAll()
            conversationLocation = ConversationLocation()
            state = probe == nil ? .chatGPTNotRunning : .reconnecting
            modernMemoryWarning = "The conversation changed or is loading. Reconnecting…"
            navigationMessage = modernMemoryWarning
            return
        }
    }

    private func applyModernSnapshot(_ snapshot: ConversationSnapshot, writeDiagnostics: Bool) {
        // Cached AX handles are not navigation targets. Keep text while clearing
        // old frames; only the latest snapshot supplies current coordinates.
        entriesByID = entriesByID.mapValues { storedEntry($0, id: $0.id, loaded: false) }
        modernLoadedCount = 0
        modernMemoryWarning = nil
        // Each refresh starts without a marker. Missing/ambiguous observations
        // cannot inherit a location from a previous view or conversation.
        conversationLocation = ConversationLocation()
        if let context = snapshot.modernContext {
            let update = modernMemory.observe(snapshot.entries.map {
                ModernPromptObservation(text: $0.fullText, nativeID: $0.modernSourceID)
            }, in: context, allowDisjointFallback: isIndexing)
            if update.didReset {
                conversationGeneration += 1
                directResponseCache.removeAll()
                verifiedResponse = nil
                capturedResponseText = ""
                showsCapturedResponse = false
                selectedResponseIDs.removeAll()
                isResponseExportMode = false
                entriesByID.removeAll()
                selectedPromptID = nil
            }
            modernConnectionReady = update.mode == .remembering && context.sessionKey != nil
            switch update.mode {
            case .remembering:
                for (index, id) in update.observedIDs.enumerated() where !id.isEmpty {
                    entriesByID[id] = storedEntry(snapshot.entries[index], id: id, loaded: true)
                    if let response = snapshot.modernResponseTexts[snapshot.entries[index].id] {
                        directResponseCache[id] = response
                    } else {
                        directResponseCache.removeValue(forKey: id)
                    }
                }
                modernLoadedCount = Set(update.observedIDs.filter { !$0.isEmpty }).count
                conversationLocation = ModernConversationLocation.locate(
                    evidence: snapshot.modernLocationEvidence, observedIDs: update.observedIDs,
                    confidentIDs: update.confidentIDs, orderedIDs: modernMemory.orderedIDs,
                    groups: modernMemory.groups, frames: zip(update.observedIDs, snapshot.entries).map {
                        (id: $0.0, frame: $0.1.frame)
                    }
                )
                if modernMemory.hasAmbiguousRepeats {
                    modernMemoryWarning = "A repeated prompt needs more neighboring context to identify its position."
                }
            case .paused:
                modernMemoryWarning = "Waiting for the chat's identity. Remembered prompts are kept."
            case .snapshotOnly:
                entriesByID = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
                modernLoadedCount = snapshot.entries.count
                let ids = snapshot.entries.map(\.id)
                conversationLocation = ModernConversationLocation.locate(
                    evidence: snapshot.modernLocationEvidence, observedIDs: ids,
                    confidentIDs: Set(ids), orderedIDs: ids, groups: [ids],
                    frames: snapshot.entries.map { (id: $0.id, frame: $0.frame) }
                )
                modernMemoryWarning = "Chat identity unavailable. Only the current view is shown."
            }
            if update.mode == .snapshotOnly {
                entries = snapshot.entries
            } else {
                entries = modernMemory.orderedIDs.compactMap { entriesByID[$0] }
            }
        } else {
            modernConnectionReady = false
            // A temporary missing AX region, settings panel, or chat loading
            // state is not evidence that the remembered conversation is empty.
            entries = modernMemory.orderedIDs.compactMap { entriesByID[$0] }
            switch snapshot.modernScanFailure {
            case "rendererUnavailable":
                modernMemoryWarning = "ChatGPT is not exposing the conversation to Accessibility. Retrying…"
            case "deadline":
                modernMemoryWarning = "Reading this conversation took too long. Retrying…"
            case "transportUnavailable":
                modernMemoryWarning = "ChatGPT’s Accessibility connection is busy. Retrying…"
            default:
                modernMemoryWarning = "Waiting for the current conversation to load…"
            }
        }
        if !entries.contains(where: { $0.id == selectedPromptID }) { selectedPromptID = nil }
        promptOrder.reset()
        locationTracker.reset()
        orderIsProvisional = modernMemory.isProvisional
        pendingOrderGroupStarts = Set(modernMemory.groups.dropFirst().compactMap(\.first))
        modernConversationTitle = modernMemory.context?.title
        modernUsesTitleIdentity = modernMemory.context != nil && modernMemory.context?.conversationID == nil
        usesStructuralOwnership = !entries.isEmpty
        chatWindowFrame = snapshot.chatWindowFrame
        if state == .needsPermission { navigationMessage = nil }
        state = modernConnectionReady ? (entries.isEmpty ? .noConversationFound : .ready) : .reconnecting
        if modernConnectionReady, navigationMessage?.hasPrefix("Reconnecting") == true { navigationMessage = nil }
        lastAutomaticRefresh = Date()
        if writeDiagnostics {
            let memoryLines = [
                "remembered=\(entries.count) loaded=\(modernLoadedCount) groups=\(modernMemory.groups.count) provisional=\(modernMemory.isProvisional)",
                "ambiguous-repeats=\(modernMemory.hasAmbiguousRepeats)",
                "memory-warning=\(modernMemoryWarning ?? "none")",
                "location=\(locationText)",
                "index-status=\(indexingStatus)",
            ]
            DiagnosticLog.write(lines: memoryLines + snapshot.diagnosticLines + (modernNavigator?.focusedFieldDiagnostic() ?? []),
                                windowFrame: snapshot.chatWindowFrame)
        }
    }

    private func storedEntry(_ entry: NavigationEntry, id: String, loaded: Bool) -> NavigationEntry {
        NavigationEntry(id: id, preview: entry.preview, fullText: entry.fullText,
                        confidence: entry.confidence, sourceRole: entry.sourceRole,
                        element: entry.element, frame: loaded ? entry.frame : nil,
                        scrollFraction: nil, modernSourceID: entry.modernSourceID)
    }

    private func merge(_ snapshot: ConversationSnapshot, automaticPassOrder: [String] = []) {
        let evidence = PromptOrderEvidence(
            observations: snapshot.entries.map { (id: $0.id, frame: $0.frame) }
        )
        promptOrder.merge(
            snapshot.entries.map(\.id),
            verifiedOrder: evidence.orderedIDs,
            automaticPassOrder: automaticPassOrder
        )
        orderIsProvisional = promptOrder.isProvisional
        pendingOrderGroupStarts = Set(promptOrder.groups.dropFirst().compactMap(\.first))
        for entry in snapshot.entries {
            entriesByID[entry.id] = entry
        }

        entries = promptOrder.ids.compactMap { entriesByID[$0] }
        if !isIndexing {
            conversationLocation = locationTracker.locate(
                orderedIDs: promptOrder.ids,
                observations: snapshot.entries.map { (id: $0.id, frame: $0.frame) },
                viewport: snapshot.viewportFrame,
                scrollFraction: snapshot.scrollFraction
            )
        }
        usesStructuralOwnership = !entries.isEmpty
        chatWindowFrame = snapshot.chatWindowFrame
        state = entries.isEmpty ? .noConversationFound : .ready
        lastAutomaticRefresh = Date()
    }

    private func clearRegistry() {
        modernConnectionReady = false
        directResponseCache.removeAll()
        modernMemory.reset()
        modernLoadedCount = 0
        modernConversationTitle = nil
        modernUsesTitleIdentity = false
        modernMemoryWarning = nil
        selectedPromptID = nil
        selectedResponseIDs.removeAll()
        conversationLocation = ConversationLocation()
        locationTracker.reset()
        entriesByID.removeAll()
        promptOrder.reset()
        orderIsProvisional = false
        pendingOrderGroupStarts.removeAll()
        entries = []
        usesStructuralOwnership = false
    }

}

enum DiagnosticLog {
    static var url: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            NewAppPreview.enabled ? "ChatGPT Navigator New App Preview" : "ChatGPT Navigator",
            isDirectory: true
        )
        return directory.appendingPathComponent("accessibility-snapshot.txt")
    }

    @discardableResult
    static func write(lines: [String], windowFrame: CGRect?) -> Bool {
        let destination = url
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let frameDescription: String
            if let windowFrame {
                frameDescription = "window x=\(Int(windowFrame.minX)) y=\(Int(windowFrame.minY)) w=\(Int(windowFrame.width)) h=\(Int(windowFrame.height))"
            } else {
                frameDescription = "window frame=none"
            }
            let header = "ChatGPT Navigator accessibility snapshot\nGenerated locally; not uploaded anywhere.\n\(frameDescription)\n\n"
            try (header + lines.joined(separator: "\n") + "\n")
                .write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            // Diagnostics are optional and must never prevent navigation.
            return false
        }
        return true
    }
}
