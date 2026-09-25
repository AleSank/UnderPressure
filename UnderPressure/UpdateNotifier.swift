import AppKit
import UserNotifications

/// Posts one macOS notification per new release found by the automatic update check;
/// clicking it opens the release page.
///
/// Permission is requested only when there is something to show (the first time an update
/// is found), never at launch. If the user declines, the menu item remains the only sign.
/// Releases the user already saw — notified, or answered through "Check for Updates…" —
/// are remembered so they are never announced twice.
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let announcedVersionKey = "lastAnnouncedUpdateVersion"
    private nonisolated static let pageURLKey = "pageURL"

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        // Set at launch, so a click on a notification delivered earlier is still handled.
        center.delegate = self
    }

    /// Announces `release` unless it was already announced or shown to the user.
    func announce(_ release: UpdateChecker.Release) {
        guard Self.shouldAnnounce(release.version, lastAnnounced: lastAnnouncedVersion) else { return }
        markSeen(release)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "UnderPressure \(release.version) is available"
            content.body = "Click to open the download page."
            content.userInfo = [Self.pageURLKey: release.pageURL.absoluteString]
            let request = UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// Records a release the user has already been told about (e.g. through the alert).
    func markSeen(_ release: UpdateChecker.Release) {
        UserDefaults.standard.set(release.version, forKey: Self.announcedVersionKey)
    }

    /// Pure rule, unit tested: announce each newer version exactly once.
    static func shouldAnnounce(_ version: String, lastAnnounced: String?) -> Bool {
        guard let lastAnnounced else { return true }
        return UpdateChecker.isVersion(version, newerThan: lastAnnounced)
    }

    private var lastAnnouncedVersion: String? {
        UserDefaults.standard.string(forKey: Self.announcedVersionKey)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even if the app happens to be active (e.g. About is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let link = response.notification.request.content.userInfo[Self.pageURLKey] as? String,
              let url = URL(string: link)
        else { return }
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
    }
}
