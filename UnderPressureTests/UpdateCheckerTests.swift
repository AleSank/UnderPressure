import Foundation
import Testing
@testable import UnderPressure

struct UpdateCheckerTests {
    @Test(arguments: [
        ("1.0.1", "1.0.0", true),
        ("1.1", "1.0.9", true),
        ("1.10.0", "1.9.2", true),
        ("2.0.0", "1.99.99", true),
        ("1.0.0", "1.0.0", false),
        ("1.0", "1.0.0", false),
        ("0.9.9", "1.0.0", false),
        ("1.0.0-beta", "1.0.0", false),
        ("", "1.0.0", false),
    ])
    func versionComparison(candidate: String, current: String, isNewer: Bool) {
        #expect(UpdateChecker.isVersion(candidate, newerThan: current) == isNewer)
    }

    @Test func parsesAGitHubRelease() throws {
        let json = #"{"tag_name": "v1.2.0", "html_url": "https://github.com/AleSank/UnderPressure/releases/tag/v1.2.0", "draft": false}"#
        let release = try #require(UpdateChecker.parseRelease(Data(json.utf8)))
        #expect(release.version == "1.2.0")
        #expect(release.pageURL.absoluteString == "https://github.com/AleSank/UnderPressure/releases/tag/v1.2.0")
    }

    @Test(arguments: [
        #"{"html_url": "https://github.com"}"#,
        #"{"tag_name": "latest", "html_url": "https://github.com"}"#,
        #"{"tag_name": "v1.2.0"}"#,
        #"not json"#,
    ])
    func rejectsUnusableResponses(json: String) {
        #expect(UpdateChecker.parseRelease(Data(json.utf8)) == nil)
    }
}

struct UpdateNotifierTests {
    @Test func eachNewerVersionIsAnnouncedOnce() {
        #expect(UpdateNotifier.shouldAnnounce("1.1.0", lastAnnounced: nil))
        #expect(UpdateNotifier.shouldAnnounce("1.2.0", lastAnnounced: "1.1.0"))
        #expect(!UpdateNotifier.shouldAnnounce("1.1.0", lastAnnounced: "1.1.0"))
        #expect(!UpdateNotifier.shouldAnnounce("1.0.9", lastAnnounced: "1.1.0"))
    }
}
