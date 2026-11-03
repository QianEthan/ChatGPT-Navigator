import ApplicationServices
import Testing
@testable import ChatGPTNavigator

struct ModernRendererActivationTests {
    @Test func unsupportedManualRequestUsesChromiumFallbackAndDoesNotRepeatKnownUnsupportedWrites() {
        var activation = ModernRendererActivation()
        var writes: [String] = []
        var enhanced = false
        let first = activation.request(process: "process-A", windowAvailable: true, forceEnhanced: false,
            set: { target, key in
                writes.append("\(target.rawValue):\(key)")
                if key == "AXManualAccessibility" { return .attributeUnsupported }
                enhanced = true
                return .success
            }, read: { _, _ in enhanced })
        #expect(first)
        #expect(activation.manualError == .attributeUnsupported)
        #expect(activation.mode == "enhanced-application-verified")
        #expect(writes == ["application:AXManualAccessibility", "application:AXEnhancedUserInterface"])
        let next = activation.request(process: "process-A", windowAvailable: true, forceEnhanced: true,
            set: { target, key in writes.append("\(target.rawValue):\(key)"); return .success },
            read: { _, _ in enhanced })
        #expect(next)
        #expect(writes.count == 2)
    }

    @Test func liveConversationContentStopsRetriesEvenIfTheActivationSetterReportedUnsupported() {
        var recovery = ModernRendererRecovery()
        _ = recovery.shouldRequest(identity: "process-A", now: 0)
        recovery.didRequest(succeeded: false, now: 0)
        recovery.observedContent(available: true, now: 1)
        let retryWhileLive = recovery.shouldRequest(identity: "process-A", now: 20)
        #expect(!retryWhileLive)
        recovery.observedContent(available: false, now: 21)
        let retryAfterLoss = recovery.shouldRequest(identity: "process-A", now: 24)
        #expect(retryAfterLoss)
    }

    @Test func normalElectronManualActivationRemainsThePreferredPath() {
        var activation = ModernRendererActivation()
        var writes: [String] = []
        let result = activation.request(process: "process-A", windowAvailable: true, forceEnhanced: false,
            set: { _, key in writes.append(key); return .success }, read: { _, _ in nil })
        #expect(result)
        #expect(writes == ["AXManualAccessibility"])
        #expect(activation.mode == "manual-request-accepted")
    }

    @Test func anAcceptedManualRequestWithoutContentEscalatesOnTheBackedOffRetry() {
        var activation = ModernRendererActivation()
        var writes: [String] = []
        _ = activation.request(process: "process-A", windowAvailable: true, forceEnhanced: false,
            set: { _, key in writes.append(key); return .success }, read: { _, _ in nil })
        let retry = activation.request(process: "process-A", windowAvailable: true, forceEnhanced: true,
            set: { _, key in writes.append(key); return .success }, read: { _, _ in nil })
        #expect(retry)
        #expect(writes.contains("AXEnhancedUserInterface"))
        #expect(activation.mode == "enhanced-application-requested-unverified")
        #expect(activation.enhancedReadback == nil)
    }

    @Test func windowFallbackIsAttemptedWhenApplicationRejectsBothAttributes() {
        var activation = ModernRendererActivation()
        var windowEnabled = false
        let result = activation.request(process: "process-A", windowAvailable: true, forceEnhanced: false,
            set: { target, _ in
                if target == .application { return .attributeUnsupported }
                windowEnabled = true
                return .success
            }, read: { target, _ in target == .window ? windowEnabled : nil })
        #expect(result)
        #expect(activation.enhancedApplicationError == .attributeUnsupported)
        #expect(activation.mode == "enhanced-window-verified")
    }

    @Test func transportFailureDoesNotSendMoreActivationRequestsToAnUnresponsiveApp() {
        var activation = ModernRendererActivation()
        var writes = 0
        let result = activation.request(process: "process-A", windowAvailable: true, forceEnhanced: false,
            set: { _, _ in writes += 1; return .cannotComplete }, read: { _, _ in nil })
        #expect(!result)
        #expect(writes == 1)
    }

    @Test func aRestartRechecksManualSupportAndAnUnsupportedFallbackDoesNotClaimSuccess() {
        var activation = ModernRendererActivation()
        let failure = activation.request(process: "process-A", windowAvailable: true, forceEnhanced: false,
            set: { _, _ in .attributeUnsupported }, read: { _, _ in nil })
        #expect(!failure)
        #expect(activation.mode == "renderer-activation-unavailable")
        var writes: [String] = []
        let restarted = activation.request(process: "process-B", windowAvailable: true, forceEnhanced: false,
            set: { _, key in writes.append(key); return .success }, read: { _, _ in nil })
        #expect(restarted)
        #expect(writes == ["AXManualAccessibility"])
        #expect(activation.enhancedApplicationError == nil)
    }
}
