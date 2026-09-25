import AppKit

/// About panel — app icon, name, tagline, version, credit, GitHub link.
///
/// Plain AppKit so the app never loads SwiftUI's runtime for one small window.
/// The panel (and its views) is released when closed; About is rarely open.
final class AboutPanelController: NSObject, NSWindowDelegate {
    private static let contentSize = NSSize(width: 320, height: 240)
    private static let githubURL = URL(string: "https://github.com/AleSank/UnderPressure")!

    private var panel: NSPanel?

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }

    @objc private func openGitHub(_ sender: Any?) {
        NSWorkspace.shared.open(Self.githubURL)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "About UnderPressure"
        panel.isReleasedWhenClosed = false
        panel.contentView = AboutView(linkTarget: self, linkAction: #selector(openGitHub(_:)))
        panel.delegate = self
        panel.center()
        return panel
    }
}

/// Content view of the About panel.
final class AboutView: NSView {
    private static let padding: CGFloat = 28
    private static let iconSide: CGFloat = 64

    init(linkTarget: AnyObject, linkAction: Selector) {
        super.init(frame: .zero)

        // The app icon from the asset catalog; NSImage picks the best representation for
        // the display size and screen scale.
        let logo = NSImageView(image: NSApp.applicationIconImage)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("UnderPressure icon")

        let title = Self.label("UnderPressure", font: .systemFont(ofSize: Self.size(.title2), weight: .semibold))

        let tagline = Self.label(
            "System Stress & Thermal Monitor for macOS",
            font: .preferredFont(forTextStyle: .callout),
            color: .secondaryLabelColor
        )
        tagline.alignment = .center
        tagline.maximumNumberOfLines = 0
        tagline.preferredMaxLayoutWidth = 320 - Self.padding * 2

        let version = Self.label(
            "Version \(Bundle.main.shortVersion)",
            font: .preferredFont(forTextStyle: .caption1),
            color: .tertiaryLabelColor
        )

        let author = Self.label("AleSank", font: .systemFont(ofSize: Self.size(.callout), weight: .medium))

        let link = NSButton(title: "", target: linkTarget, action: linkAction)
        link.isBordered = false
        link.attributedTitle = NSAttributedString(
            string: "github.com/AleSank/UnderPressure",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.preferredFont(forTextStyle: .caption1),
            ]
        )

        let credit = NSStackView(views: [author, link])
        credit.orientation = .vertical
        credit.spacing = 4

        let stack = NSStackView(views: [logo, title, tagline, version, credit])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(18, after: version)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: Self.iconSide),
            logo.heightAnchor.constraint(equalToConstant: Self.iconSide),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.padding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        return label
    }

    private static func size(_ style: NSFont.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize
    }
}

extension Bundle {
    /// Marketing version (`CFBundleShortVersionString`), shown in About and compared with
    /// GitHub releases by `UpdateChecker`.
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}
