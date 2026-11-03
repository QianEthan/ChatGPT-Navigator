import ApplicationServices
import CoreGraphics
import Foundation

// AXUIElement is an immutable CF reference. Modern handles are retained across the
// worker boundary; traversal and mutations remain serialized in ModernAXWorker.
struct NavigationEntry: Identifiable, @unchecked Sendable {
    enum Confidence {
        case userMessage
        case conversationText
    }

    let id: String
    let preview: String
    let fullText: String
    let confidence: Confidence
    let sourceRole: String
    let element: AXUIElement
    let frame: CGRect?
    let scrollFraction: Double?
    var modernSourceID: String? = nil
}

struct ConversationSnapshot: Sendable {
    let entries: [NavigationEntry]
    let chatWindowFrame: CGRect?
    let usedStructuralOwnership: Bool
    let diagnosticLines: [String]
    var viewportFrame: CGRect? = nil
    var scrollFraction: Double? = nil
    var modernContext: ModernConversationContext? = nil
    var modernLocationEvidence: ModernLocationEvidence? = nil
    var modernIndexEvidence: ModernIndexEvidence? = nil
    var modernScrollPoint: CGPoint? = nil
    var modernResponseTexts: [String: String] = [:]
    var modernScanFailure: String? = nil
}

enum NavigatorState: Equatable {
    case needsPermission
    case chatGPTNotRunning
    case noConversationFound
    case ready
    case reconnecting

    var message: String {
        switch self {
        case .needsPermission:
            return "Accessibility permission is required"
        case .chatGPTNotRunning:
            return "Open ChatGPT to begin"
        case .noConversationFound:
            return "No structurally identified user messages found"
        case .reconnecting:
            return "Reconnecting to the current conversation…"
        case .ready:
            return "Connected to ChatGPT"
        }
    }
}
