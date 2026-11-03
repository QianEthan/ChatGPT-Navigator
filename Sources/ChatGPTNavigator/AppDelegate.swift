import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = NavigatorModel()
    private var panel: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let testPath = Bundle.main.url(forResource: "ExportSelfTest", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let argumentIndex = CommandLine.arguments.firstIndex(of: "--export-self-test")
        let argumentPath = argumentIndex.flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
        if let path = testPath ?? argumentPath {
            let directory = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            Task { @MainActor in
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let defaultResponse = #"A fraction \(\frac{1}{\sqrt{x^2+1}}\), and $$\begin{bmatrix}1&2\\3&4\end{bmatrix}$$"# + String(repeating: "\n\nA paragraph explaining this equation in detail.\n", count: 90)
                    let response = Bundle.main.url(forResource: "ExportInput", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? defaultResponse
                    for format in ResponseExportFormat.allCases {
                        try await MathResponseExporter.write(items: [ResponseExportItem(prompt: "Math verification", response: response)], to: directory.appendingPathComponent("sample.\(format.filenameExtension)"), format: format)
                    }
                    try "OK".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                } catch {
                    try? error.localizedDescription.write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
            return
        }
        configureMainMenu()
        createPanel()
        observeTargetWindow()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createPanel() {
        let rootView = SidebarView(model: model)
        let hostingController = NSHostingController(rootView: rootView)

        let panel = NSWindow(
            contentRect: NSRect(x: 120, y: 160, width: 300, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "ChatGPT Navigator"
        panel.titleVisibility = .visible
        panel.contentViewController = hostingController
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = NSSize(width: 280, height: 420)
        panel.setFrameAutosaveName("ChatGPTNavigatorNewAppPreviewPanel")
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
    }

    private func observeTargetWindow() {
        model.$chatWindowFrame
            .removeDuplicates { first, second in
                first == second
            }
            .sink { [weak self] frame in
                guard let self, let frame else { return }
                self.attachPanel(besideAXFrame: frame)
            }
            .store(in: &cancellables)
    }

    private func attachPanel(besideAXFrame targetFrame: CGRect) {
        guard let panel else { return }

        let targetAppKitFrame = appKitFrame(fromAXFrame: targetFrame)
        let screen = NSScreen.screens.first { screen in
            screen.frame.intersects(targetAppKitFrame)
        } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let gap: CGFloat = 10
        let desiredHeight = min(max(targetAppKitFrame.height, 480), visible.height)
        var proposed = NSRect(
            x: targetAppKitFrame.minX - panel.frame.width - gap,
            y: min(max(targetAppKitFrame.minY, visible.minY), visible.maxY - desiredHeight),
            width: panel.frame.width,
            height: desiredHeight
        )

        if proposed.minX < visible.minX {
            proposed.origin.x = targetAppKitFrame.maxX + gap
        }
        proposed.origin.x = min(max(proposed.minX, visible.minX), visible.maxX - proposed.width)
        proposed.origin.y = min(max(proposed.minY, visible.minY), visible.maxY - proposed.height)

        panel.setFrame(proposed, display: true, animate: false)
    }

    private func appKitFrame(fromAXFrame frame: CGRect) -> CGRect {
        let matchingScreen = NSScreen.screens.first { screen in
            let axScreenFrame = CGRect(
                x: screen.frame.minX,
                y: NSScreen.screens.map(\.frame.maxY).max()! - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            return axScreenFrame.intersects(frame)
        } ?? NSScreen.main

        guard let screen = matchingScreen else { return frame }
        let globalTop = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
        return CGRect(
            x: frame.minX,
            y: globalTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About ChatGPT Navigator",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ChatGPT Navigator",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}
