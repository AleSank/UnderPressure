import Foundation

/// Looks for a newer release on GitHub and reports it; the menu shows it as an item that
/// opens the release page. The app never downloads or installs anything itself.
///
/// No timer: it checks once at launch, then at most once every 24 h when the menu opens
/// (the only place the notice can be seen), plus whenever the user picks "Check for
/// Updates…" (`checkNow`). One anonymous HTTPS request to the public
/// GitHub API (`releases/latest`, which skips drafts and pre-releases); nothing about the
/// user or the Mac is sent. Failures (offline, rate limit) are silent and retried later.
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let pageURL: URL
    }

    /// Result of a check the user asked for.
    enum Outcome {
        case available(Release)
        case upToDate
        case failed
    }

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/AleSank/UnderPressure/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let requestTimeout: TimeInterval = 15

    /// A release newer than the running app, once found.
    private(set) var availableRelease: Release?
    /// Invoked on the main thread when `availableRelease` changes; `userInitiated` tells
    /// whether it came from "Check for Updates…" (the user already gets an answer then).
    var onUpdate: ((_ userInitiated: Bool) -> Void)?

    let currentVersion: String
    private var lastCheck: Date?
    private var isChecking = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        return URLSession(configuration: configuration)
    }()

    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    /// Automatic check: skipped if one ran in the last 24 h or is still running.
    func checkIfDue(now: Date = Date()) {
        if let lastCheck, now.timeIntervalSince(lastCheck) < Self.checkInterval { return }
        guard !isChecking else { return }
        beginCheck()
        Task { _ = await check(userInitiated: false) }
    }

    /// Check requested by the user: always runs, and reports the outcome.
    func checkNow(completion: @escaping (Outcome) -> Void) {
        beginCheck()
        Task { completion(await check(userInitiated: true)) }
    }

    /// Marks the check as started before any suspension, so a second automatic check
    /// can't slip in while the request is being set up.
    private func beginCheck() {
        isChecking = true
        lastCheck = Date()
    }

    private func check(userInitiated: Bool) async -> Outcome {
        defer { isChecking = false }
        guard let latest = await fetchLatestRelease() else { return .failed }
        guard Self.isVersion(latest.version, newerThan: currentVersion) else { return .upToDate }
        if latest != availableRelease {
            availableRelease = latest
            onUpdate?(userInitiated)
        }
        return .available(latest)
    }

    private func fetchLatestRelease() async -> Release? {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Self.parseRelease(data)
    }

    // MARK: - Pure helpers (unit tested)

    /// `tag_name` (e.g. `v1.2.0`) and `html_url` from a GitHub release JSON.
    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let version = normalizedVersion(tag)
        else { return nil }
        return Release(version: version, pageURL: page)
    }

    /// Numeric, component-wise comparison: `1.10.0` > `1.9.2`, `1.1` == `1.1.0`.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let lhs = components(candidate), let rhs = components(current) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// `v1.2.0` → `1.2.0`; `nil` unless it is dot-separated numbers.
    private static func normalizedVersion(_ tag: String) -> String? {
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return components(version) == nil ? nil : version
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count && !numbers.isEmpty ? numbers : nil
    }
}
