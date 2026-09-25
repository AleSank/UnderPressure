import AppKit

/// Pure AppKit entry point: an `LSUIElement` agent (no Dock icon) whose whole UI is
/// the status item. Avoiding the SwiftUI `App` lifecycle keeps the resident
/// footprint small for an always-running utility.
@main
enum UnderPressureApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `NSApplication.delegate` is weak; keep ours alive for the run loop's lifetime.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = UnderPressureMonitor()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted by the app: don't add a menubar item or a login item then.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.mainMenu = Self.makeMainMenu()
        statusItem = StatusItemController(monitor: monitor)
        monitor.start()
        LaunchAtLogin.enableOnFirstLaunch()
    }

    /// Invisible for an agent app, but provides ⌘W / ⌘Q while the About panel is key.
    private static func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit UnderPressure", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
