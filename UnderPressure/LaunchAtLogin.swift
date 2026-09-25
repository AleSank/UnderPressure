import Foundation
import ServiceManagement

/// "Launch at Login" through `SMAppService.mainApp` (macOS 13+): no helper app, no
/// entitlement. macOS shows the user a notification when the item is added, and lists it
/// in System Settings → General → Login Items.
///
/// Turned on once, on the first launch — a menubar monitor is only useful if it is always
/// there — then left entirely to the user (menu toggle or System Settings).
enum LaunchAtLogin {
    private static let enabledByDefaultKey = "didEnableLaunchAtLoginByDefault"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: enabledByDefaultKey) else { return }
        defaults.set(true, forKey: enabledByDefaultKey)
        setEnabled(true)
    }

    /// Flips the setting. When macOS refuses (the user disabled the item in System
    /// Settings, so it needs their approval there), opens the Login Items pane instead.
    static func toggle() {
        guard SMAppService.mainApp.status != .requiresApproval, setEnabled(!isEnabled) else {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
    }

    @discardableResult
    private static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
