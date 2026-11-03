import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: NavigatorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.isResponseExportMode {
                selectionCopyControls
                Divider()
            }

            if model.state == .needsPermission {
                permissionView
            } else if model.filteredEntries.isEmpty {
                emptyView
            } else {
                entryList
            }

            Divider()
            footer
        }
        .frame(minWidth: 280, idealWidth: 300, minHeight: 420)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundStyle(.tint)
                Text("Prompts")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(model.entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.toggleResponseExportMode()
                } label: {
                    Image(systemName: model.isResponseExportMode ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                        .foregroundStyle(model.isResponseExportMode ? Color.accentColor : Color.primary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!model.permissionGranted || (NewAppPreview.enabled && !model.modernConnectionReady) || model.isIndexing || model.isExportingResponses || model.isNavigating)
                .accessibilityLabel(model.isResponseExportMode ? "Exit download mode" : "Download replies")
                .help(model.isResponseExportMode ? "Exit download mode" : "Select a prompt and download its reply")
                Button {
                    if model.isIndexing {
                        model.cancelIndexing()
                    } else {
                        model.indexEntireConversation()
                    }
                } label: {
                    Image(systemName: model.isIndexing ? "stop.fill" : "arrow.up.and.down.text.horizontal")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!model.permissionGranted || (NewAppPreview.enabled && !model.modernConnectionReady) || model.isResponseExportMode || model.isExportingResponses || model.isNavigating)
                .accessibilityLabel(model.isIndexing ? "Stop indexing" : "Index Entire Conversation")
                .help(model.isIndexing ? "Stop indexing and keep discovered prompts" :
                    "Index the full conversation from newest to oldest. Keep the pointer still while it runs.")
            }
            if model.isIndexing {
                if NewAppPreview.enabled {
                    ProgressView().controlSize(.small)
                    Text("Keep the pointer still. Move it or press Stop to interrupt.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: model.indexingProgress).progressViewStyle(.linear)
                }
            }
            if model.isExportingResponses {
                ProgressView(value: model.responseExportProgress)
                    .progressViewStyle(.linear)
            }
            Label(model.locationText, systemImage: "location.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(NewAppPreview.enabled ? "Tracks the middle of ChatGPT’s visible conversation. Green shows your reading location; the selected row stays separate. Approx. means the location is estimated." :
                    "Tracks the middle of ChatGPT's conversation viewport. Approx. means a boundary is not currently loaded. Prompt numbers refer to remembered prompts.")
            if model.orderIsProvisional {
                Text("~ Prompt numbers are provisional")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Scroll through overlapping sections to establish their chronological order. Disconnected sections stay below Position pending until linked.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var selectionCopyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.isExportingResponses ? model.responseExportStatus : "Select one or more prompts. Their replies will be combined in chat order.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Format").font(.caption)
                Picker("Format", selection: $model.responseExportFormat) {
                    ForEach(ResponseExportFormat.allCases) { format in Text(format.label).tag(format) }
                }
                .labelsHidden()
                .disabled(model.isExportingResponses)
                Spacer()
            }
            HStack {
                Button(model.isExportingResponses ? "Stop" : "Cancel") { model.cancelResponseExport() }
                Spacer()
                Text("\(model.selectedResponseIDs.count) selected").font(.caption)
                Button(model.selectedResponseIDs.count > 1 ? "Download replies" : "Download reply") { model.downloadSelectedReply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedResponseIDs.isEmpty || model.isExportingResponses || model.isNavigating)
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private var permissionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "figure.hand.raised")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Allow Accessibility access")
                .font(.title3.weight(.semibold))

            Text("ChatGPT Navigator uses macOS Accessibility to read loaded user prompts in the new ChatGPT app. It does not change your chats or use the network.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Request Access") {
                model.requestPermission()
            }
            .buttonStyle(.borderedProminent)

            Button("Open Accessibility Settings") {
                model.revealAccessibilitySettings()
            }
            .buttonStyle(.link)

            if let message = model.navigationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: model.state == .chatGPTNotRunning ? "bubble.left.and.exclamationmark.bubble.right" : "text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(model.state.message)
                .font(.headline)
            Text(emptyExplanation)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 230)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var emptyExplanation: String {
        switch model.state {
        case .chatGPTNotRunning:
            return "Launch ChatGPT and open a conversation."
        case .noConversationFound:
            return "Open a conversation in ChatGPT. Its loaded user prompts will appear here."
        default:
            return "Visible prompts appear here automatically. Use Reconnect if the conversation is still unavailable."
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(Array(model.filteredEntries.enumerated()), id: \.element.id) { index, entry in
                    if model.pendingOrderGroupStarts.contains(entry.id) {
                        HStack(spacing: 8) {
                            Rectangle().fill(.secondary.opacity(0.2)).frame(height: 1)
                            Text("Position pending")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    if !model.isIndexing, !model.isNavigating,
                       model.conversationLocation.markerBeforeID == entry.id {
                        locationMarker
                    }
                    PromptRailRow(
                        number: index + 1,
                        numberIsProvisional: model.orderIsProvisional,
                        text: entry.fullText,
                        isSelected: model.isResponseExportMode
                            ? model.selectedResponseIDs.contains(entry.id)
                            : model.selectedPromptID == entry.id,
                        isCurrent: !model.isIndexing && !model.isExportingResponses && !model.isNavigating
                            && model.conversationLocation.highlightedID == entry.id,
                        isApproximate: model.conversationLocation.isApproximate,
                        showsExportSelection: model.isResponseExportMode,
                        isExportSelected: model.selectedResponseIDs.contains(entry.id)
                    ) {
                        if model.isResponseExportMode {
                            model.toggleResponseSelection(for: entry)
                        } else {
                            model.navigate(to: entry)
                        }
                    }
                    .disabled(model.isIndexing || model.isExportingResponses || (NewAppPreview.enabled && !model.modernConnectionReady))
                    if !model.isIndexing, !model.isNavigating,
                       model.conversationLocation.markerAfterID == entry.id {
                        locationMarker
                    }
                }
            }
            .padding(8)
        }
    }

    private var locationMarker: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.green).frame(width: 5, height: 5)
            Rectangle().fill(Color.green.opacity(0.35)).frame(height: 1)
            Text(model.conversationLocation.isApproximate ? "Approx. location" : "You are here")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.locationText)
    }

    private var footer: some View {
        Group {
            if NewAppPreview.enabled {
                VStack(alignment: .leading, spacing: 7) {
                    if let warning = model.modernMemoryWarning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if model.isNavigating {
                            Button("Stop navigation") { model.stopModernNavigation() }
                        }
                        Button("Reconnect") { model.reconnectModernConversation() }
                    }
                    Text("\(model.entries.count) remembered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Save diagnostics") { model.revealDiagnosticLog() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isNavigating || model.isIndexing || model.isExportingResponses)
                        .help("Save the loaded conversation's text, math structure, and button positions to a local file, then show it in Finder.")
                    if let message = model.navigationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(model.footerText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                    }
                    if let message = model.navigationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .contextMenu {
            if NewAppPreview.enabled && model.isNavigating {
                Button("Stop navigation") { model.stopModernNavigation() }
            }
            Button(NewAppPreview.enabled ? "Save and reveal diagnostic snapshot" : "Reveal diagnostic snapshot") {
                model.revealDiagnosticLog()
            }
            .disabled(model.isNavigating || model.isIndexing)
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .reconnecting:
            return .orange
        case .ready:
            return .green
        case .needsPermission:
            return .orange
        case .chatGPTNotRunning, .noConversationFound:
            return .secondary
        }
    }
}

private struct PromptRailRow: View {
    let number: Int
    let numberIsProvisional: Bool
    let text: String
    let isSelected: Bool
    let isCurrent: Bool
    let isApproximate: Bool
    let showsExportSelection: Bool
    let isExportSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? Color.green : isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: 18)
                Text("\(numberIsProvisional ? "~" : "")\(number)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: numberIsProvisional ? 26 : 18, alignment: .trailing)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: isApproximate ? "location" : "location.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                if showsExportSelection {
                    Image(systemName: isExportSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isExportSelected ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.1)
                    : Color.primary.opacity(isHovered ? 0.055 : 0),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(text)
        .accessibilityLabel("\(numberIsProvisional ? "Provisional prompt" : "Prompt") \(number): \(text)")
        .accessibilityValue(
            showsExportSelection
                ? (isExportSelected ? "Selected for response export" : "Not selected for response export")
                : (isCurrent ? (isApproximate ? "Approximate current location" : "Current location") : "")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
