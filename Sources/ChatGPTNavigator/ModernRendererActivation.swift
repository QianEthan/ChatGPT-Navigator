import ApplicationServices
import Foundation

/// Chromium's native-shell-only AX mode is not a usable transcript. Electron's
/// manual attribute is preferred, with Chromium's enhanced UI request as fallback.
/// Never toggle either attribute off, or reset another assistive client's mode.
struct ModernRendererActivation {
    enum Target: String { case application, window }
    private var processIdentity: String?
    private(set) var manualError: AXError?
    private(set) var enhancedApplicationError: AXError?
    private(set) var enhancedWindowError: AXError?
    private(set) var mode = "not-requested"
    private(set) var enhancedReadback: Bool?

    mutating func request(process: String, windowAvailable: Bool, forceEnhanced: Bool,
                          set: (Target, String) -> AXError,
                          read: (Target, String) -> Bool?) -> Bool {
        if processIdentity != process {
            self = Self()
            processIdentity = process
        }
        // An unsupported attribute will not become supported through polling.
        // Retry transport failures, but retain unsupported status per launch.
        if manualError != .attributeUnsupported {
            manualError = set(.application, "AXManualAccessibility")
        }
        if manualError == .success, !forceEnhanced {
            mode = "manual-request-accepted"
            return true
        }
        if manualError == .cannotComplete || manualError == .invalidUIElement {
            mode = "activation-transport-unavailable"
            return false
        }
        let targets: [Target] = windowAvailable ? [.application, .window] : [.application]
        for target in targets {
            if read(target, "AXEnhancedUserInterface") == true {
                enhancedReadback = true
                mode = "enhanced-\(target.rawValue)-verified"
                return true
            }
            let error = set(target, "AXEnhancedUserInterface")
            if target == .application { enhancedApplicationError = error }
            else { enhancedWindowError = error }
            let readback = read(target, "AXEnhancedUserInterface")
            enhancedReadback = readback
            if readback == true {
                mode = "enhanced-\(target.rawValue)-verified"
                return true
            }
            if error == .success, readback == nil {
                // Some Chromium versions apply the mode asynchronously. The
                // transcript landmark, not this setter result, proves readiness.
                mode = "enhanced-\(target.rawValue)-requested-unverified"
                return true
            }
        }
        mode = "renderer-activation-unavailable"
        return false
    }

    var diagnostic: String {
        func code(_ error: AXError?) -> String { error.map { String($0.rawValue) } ?? "not-attempted" }
        return "renderer-activation=\(mode) manual-error=\(code(manualError)) enhanced-app-error=\(code(enhancedApplicationError)) enhanced-window-error=\(code(enhancedWindowError)) enhanced-readback=\(enhancedReadback.map(String.init) ?? "unavailable")"
    }
}
