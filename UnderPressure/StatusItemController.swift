import AppKit

/// AppKit status item + `NSMenu` — avoids SwiftUI `MenuBarExtra` `.menu` ghost highlight
/// where plain `Text` metric rows steal selection when hovering About/Quit.
///
/// Driven by `UnderPressureMonitor.onUpdate`: new stress is handed to `LiquidIconAnimator`
/// (which owns the icon), and metric rows are refreshed only while the menu is open.
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let menuContentWidth: CGFloat = 220
    private static let metricLeadingInset: CGFloat = 14
    private static let metricFieldHeight: CGFloat = 16
    /// Metric rows are as tall as a standard text item (it varies by macOS version), so the
    /// gap above CPU equals the gap below Quit without any spacer.
    private static let metricRowHeight = standardItemHeight()

    private let monitor: UnderPressureMonitor
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let aboutPanel = AboutPanelController()
    private let updateChecker = UpdateChecker(currentVersion: Bundle.main.shortVersion)
    private let updateNotifier = UpdateNotifier()
    private let iconAnimator: LiquidIconAnimator

    private let cpuField = StatusItemController.metricField()
    private let gpuField = StatusItemController.metricField()
    private let ramField = StatusItemController.metricField()
    private let diskField = StatusItemController.metricField()
    private let topAppsHeaderField = StatusItemController.metricField(size: .small)
    private let topAppFields = (0..<UnderPressureMonitor.topAppCount).map { _ in
        StatusItemController.metricField(size: .small)
    }
    private let pressureField = StatusItemController.metricField(size: .small)
    private let thermalField = StatusItemController.metricField(size: .small)
    private let errorField = StatusItemController.metricField(size: .small)

    private var topAppsHeaderItem: NSMenuItem?
    private var topAppItems: [NSMenuItem] = []
    private var pressureItem: NSMenuItem?
    private var thermalItem: NSMenuItem?
    private var errorItem: NSMenuItem?
    private var isMenuOpen = false
    /// "Check for Updates…"; becomes "Update Available: x.y.z…" (opens the release page)
    /// once `UpdateChecker` finds a newer release.
    private let updateItem = NSMenuItem(
        title: "Check for Updates…",
        action: #selector(updateItemClicked(_:)),
        keyEquivalent: ""
    )
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin(_:)),
        keyEquivalent: ""
    )

    init(monitor: UnderPressureMonitor) {
        self.monitor = monitor
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        self.iconAnimator = LiquidIconAnimator(button: statusItem.button)
        super.init()

        menu.delegate = self
        statusItem.button?.setAccessibilityLabel("UnderPressure")
        statusItem.menu = menu

        buildMenu()
        updateChecker.onUpdate = { [weak self] userInitiated in
            self?.showAvailableUpdate(notify: !userInitiated)
        }
        updateChecker.checkIfDue()
        monitor.onUpdate = { [weak self] in
            self?.monitorDidUpdate()
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateChecker.checkIfDue()
        isMenuOpen = true
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        detailItems.forEach { $0.isHidden = true }
        monitor.showsMenuDetails = true
        updateMetricFields()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        monitor.showsMenuDetails = false
    }

    // MARK: - Updates

    private func monitorDidUpdate() {
        iconAnimator.setStress(monitor.stress)
        if isMenuOpen {
            updateMetricFields()
        }
    }

    private func updateMetricFields() {
        set(cpuField, MenuCopy.cpuRow(monitor), tone: MenuCopy.cpuTone(monitor))
        set(gpuField, MenuCopy.gpuRow(monitor), tone: MenuCopy.gpuTone(monitor))
        set(ramField, MenuCopy.ramRow(monitor), tone: MenuCopy.ramTone(monitor))
        set(diskField, MenuCopy.diskRow(monitor), tone: MenuCopy.diskTone(monitor))

        for (index, field) in topAppFields.enumerated() {
            show(MenuCopy.topAppRow(monitor, at: index), in: field, item: topAppItems[index])
        }
        topAppsHeaderItem?.isHidden = topAppItems.allSatisfy(\.isHidden)
        show(MenuCopy.pressureRow(monitor), in: pressureField, item: pressureItem)
        show(MenuCopy.thermalRow(monitor), in: thermalField, item: thermalItem)
        show(MenuCopy.sensorNotice(monitor), in: errorField, item: errorItem)
    }

    /// Secondary rows start hidden on each opening and appear once relevant. While the
    /// menu stays open they don't disappear again (their text keeps updating), so the
    /// menu never shrinks or jumps under the pointer.
    private func show(_ row: MenuCopy.DetailRow, in field: NSTextField, item: NSMenuItem?) {
        field.stringValue = row.text
        field.textColor = row.tone.nsColor
        if row.isRelevant {
            item?.isHidden = false
        }
    }

    private var detailItems: [NSMenuItem] {
        [topAppsHeaderItem, pressureItem, thermalItem, errorItem].compactMap { $0 } + topAppItems
    }

    private func set(_ field: NSTextField, _ text: String, tone: MenuCopy.Tone) {
        field.stringValue = text
        field.textColor = tone.nsColor
    }

    // MARK: - Menu structure

    private func buildMenu() {
        menu.addItem(viewItem(field: cpuField))
        menu.addItem(viewItem(field: gpuField))
        menu.addItem(viewItem(field: ramField))
        menu.addItem(viewItem(field: diskField))

        topAppsHeaderField.stringValue = MenuCopy.topAppsHeader
        topAppsHeaderItem = hiddenItem(field: topAppsHeaderField)
        topAppItems = topAppFields.map { hiddenItem(field: $0) }
        pressureItem = hiddenItem(field: pressureField)
        thermalItem = hiddenItem(field: thermalField)
        errorItem = hiddenItem(field: errorField)

        menu.addItem(.separator())

        updateItem.target = self
        menu.addItem(updateItem)

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        let about = NSMenuItem(title: "About", action: #selector(openAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Custom-view rows are not part of AppKit’s highlight tracking — only the real items
    /// (Check for Updates, Launch at Login, About, Quit) highlight.
    /// Fixed-size container + clipping monospaced labels keep the menu width stable.
    private func viewItem(field: NSTextField) -> NSMenuItem {
        let height = Self.metricRowHeight
        let width = Self.metricLeadingInset + Self.menuContentWidth + 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        field.frame = NSRect(
            x: Self.metricLeadingInset,
            y: (height - Self.metricFieldHeight) / 2,
            width: Self.menuContentWidth,
            height: Self.metricFieldHeight
        )
        container.addSubview(field)

        let item = NSMenuItem()
        item.view = container
        item.isEnabled = false
        return item
    }

    private func hiddenItem(field: NSTextField) -> NSMenuItem {
        let item = viewItem(field: field)
        item.isHidden = true
        menu.addItem(item)
        return item
    }

    /// Height of one plain text item, measured once from a throwaway menu (it varies by
    /// macOS version). Falls back to 22 pt if the measurement is implausible.
    private static func standardItemHeight() -> CGFloat {
        let probe = NSMenu()
        probe.addItem(withTitle: "Quit", action: nil, keyEquivalent: "")
        let one = probe.size.height
        probe.addItem(withTitle: "Quit", action: nil, keyEquivalent: "")
        let height = probe.size.height - one
        return height >= metricFieldHeight ? height : 22
    }

    private enum FontSize {
        case body, small
    }

    private static func metricField(size: FontSize = .body) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byClipping
        switch size {
        case .body:
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case .small:
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.textColor = .secondaryLabelColor
        }
        return field
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        LaunchAtLogin.toggle()
    }

    /// Menu item always; a macOS notification only for automatic checks (a manual check
    /// answers with an alert instead).
    private func showAvailableUpdate(notify: Bool) {
        guard let release = updateChecker.availableRelease else { return }
        updateItem.title = "Update Available: \(release.version)…"
        if notify {
            updateNotifier.announce(release)
        }
    }

    @objc private func updateItemClicked(_ sender: Any?) {
        if let release = updateChecker.availableRelease {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        updateChecker.checkNow { [weak self] outcome in
            self?.presentUpdateOutcome(outcome)
        }
    }

    /// Answer to "Check for Updates…" — always shown, so the click never goes unanswered.
    private func presentUpdateOutcome(_ outcome: UpdateChecker.Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .available(let release):
            alert.messageText = "UnderPressure \(release.version) is available"
            alert.informativeText = "You have version \(updateChecker.currentVersion). "
                + "Download the new version from GitHub and replace the app in Applications."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        case .upToDate:
            alert.messageText = "UnderPressure is up to date"
            alert.informativeText = "Version \(updateChecker.currentVersion) is the latest version."
        case .failed:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Check your internet connection and try again later."
        }
        // An agent app must come to the front, or the alert opens behind other windows.
        NSApp.activate()
        let response = alert.runModal()
        if case .available(let release) = outcome {
            updateNotifier.markSeen(release)
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.pageURL)
            }
        }
    }

    @objc private func openAbout(_ sender: Any?) {
        aboutPanel.show()
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }
}
