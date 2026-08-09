import Testing
import Foundation
@testable import LocalmemCore

private func release(_ tag: String,
                     body: String? = nil,
                     draft: Bool = false,
                     prerelease: Bool = false,
                     assets: [GitHubReleaseInfo.GitHubAsset]? = nil,
                     id: Int = Int.random(in: 1...1_000_000)) -> GitHubReleaseInfo {
    GitHubReleaseInfo(id: id, tagName: tag, body: body,
                      htmlUrl: "https://example.invalid/\(tag)",
                      draft: draft, prerelease: prerelease, assets: assets)
}

@Suite struct UpdateDecisionTests {

    // MARK: - Which release gets offered

    @Test func offersNothingWhenCurrent() {
        let outcome = UpdateDecision.evaluate(
            releases: [release("v1.0.1"), release("v1.0.0")],
            currentVersion: "1.0.1")
        #expect(outcome.latest == nil)
        #expect(outcome.hasSecurityFix == false)
    }

    @Test func offersTheNewerRelease() {
        let outcome = UpdateDecision.evaluate(
            releases: [release("v1.1.0"), release("v1.0.1")],
            currentVersion: "1.0.1")
        #expect(outcome.latest?.cleanVersion == "1.1.0")
    }

    /// GitHub returns releases newest-created first. A patch backport cut after
    /// a minor release therefore leads the list while being the *older*
    /// version; taking the first entry offered 1.0.2 to someone who could have
    /// had 1.1.0.
    @Test func backportPublishedAfterMinorDoesNotWin() {
        let outcome = UpdateDecision.evaluate(
            releases: [release("v1.0.2"), release("v1.1.0"), release("v1.0.1")],
            currentVersion: "1.0.1")
        #expect(outcome.latest?.cleanVersion == "1.1.0")
    }

    @Test func skipsDraftsAndPrereleases() {
        let outcome = UpdateDecision.evaluate(
            releases: [
                release("v2.0.0", draft: true),
                release("v1.9.0", prerelease: true),
                release("v1.1.0"),
            ],
            currentVersion: "1.0.1")
        #expect(outcome.latest?.cleanVersion == "1.1.0")
    }

    @Test func emptyListOffersNothing() {
        let outcome = UpdateDecision.evaluate(releases: [], currentVersion: "1.0.1")
        #expect(outcome.latest == nil)
    }

    /// A draft of the only newer version must not leave the user "up to date"
    /// *and* must not be offered.
    @Test func onlyNewerReleaseBeingADraftMeansUpToDate() {
        let outcome = UpdateDecision.evaluate(
            releases: [release("v1.1.0", draft: true), release("v1.0.1")],
            currentVersion: "1.0.1")
        #expect(outcome.latest == nil)
    }

    // MARK: - Security flagging

    /// The reason the whole list is fetched rather than `/releases/latest`: the
    /// fix was in 1.1.0, the user is jumping to 1.3.0, and 1.3.0's own notes
    /// say nothing about security.
    @Test func securityFixInAnInterveningReleaseIsReported() {
        let outcome = UpdateDecision.evaluate(
            releases: [
                release("v1.3.0", body: "Folder rename."),
                release("v1.1.0", body: "## Security\nFixes a path traversal in import."),
                release("v1.0.1", body: "## Security\nAn older fix the user already has."),
            ],
            currentVersion: "1.0.1")
        #expect(outcome.latest?.cleanVersion == "1.3.0")
        #expect(outcome.hasSecurityFix)
    }

    /// A fix in a release the user is already running must not raise the
    /// warning — only releases *newer* than the running version are scanned.
    @Test func securityFixInAlreadyInstalledReleaseIsIgnored() {
        let outcome = UpdateDecision.evaluate(
            releases: [
                release("v1.1.0", body: "Ordinary release."),
                release("v1.0.1", body: "## Security\nAlready installed."),
            ],
            currentVersion: "1.0.1")
        #expect(outcome.latest?.cleanVersion == "1.1.0")
        #expect(outcome.hasSecurityFix == false)
    }

    @Test func securityHeadingIsCaseInsensitiveAndMarkerAlsoWorks() {
        #expect(UpdateDecision.evaluate(
            releases: [release("v1.1.0", body: "## SECURITY\nfix")],
            currentVersion: "1.0.1").hasSecurityFix)
        #expect(UpdateDecision.evaluate(
            releases: [release("v1.1.0", body: "Notes [security] here")],
            currentVersion: "1.0.1").hasSecurityFix)
    }

    /// Notes that mention security in passing must not raise the warning —
    /// which is why a bare "security fix" substring is not matched.
    @Test func prosePassingMentionOfSecurityDoesNotFlag() {
        let outcome = UpdateDecision.evaluate(
            releases: [release("v1.1.0", body: "This release contains no security fixes.")],
            currentVersion: "1.0.1")
        #expect(outcome.hasSecurityFix == false)
    }

    @Test func missingBodyDoesNotFlag() {
        let outcome = UpdateDecision.evaluate(
            releases: [release("v1.1.0", body: nil)],
            currentVersion: "1.0.1")
        #expect(outcome.latest != nil)
        #expect(outcome.hasSecurityFix == false)
    }

    // MARK: - Asset selection

    @Test func picksTheDmgAsset() {
        let rel = release("v1.1.0", assets: [
            .init(name: "checksums.txt", browserDownloadUrl: "https://example.invalid/checksums.txt"),
            .init(name: "Localmem.dmg", browserDownloadUrl: "https://example.invalid/Localmem.dmg"),
        ])
        #expect(rel.dmgDownloadUrl == "https://example.invalid/Localmem.dmg")
    }

    /// A release published without a DMG must report nil so the app can fall
    /// back to opening the release page rather than downloading nothing.
    @Test func noDmgAssetReportsNil() {
        #expect(release("v1.1.0", assets: [
            .init(name: "checksums.txt", browserDownloadUrl: "https://example.invalid/c.txt"),
        ]).dmgDownloadUrl == nil)
        #expect(release("v1.1.0", assets: nil).dmgDownloadUrl == nil)
        #expect(release("v1.1.0", assets: []).dmgDownloadUrl == nil)
    }

    // MARK: - Tag parsing

    @Test func stripsLeadingVFromTag() {
        #expect(release("v1.2.3").cleanVersion == "1.2.3")
        #expect(release("1.2.3").cleanVersion == "1.2.3")
    }

    // MARK: - Decoding the API shape

    @Test func decodesTheGitHubPayloadShape() throws {
        let json = """
        [{
          "id": 42,
          "tag_name": "v1.1.0",
          "name": "Localmem 1.1.0",
          "body": "## Security\\nFixed.",
          "html_url": "https://github.com/localmemai/localmem-app/releases/tag/v1.1.0",
          "draft": false,
          "prerelease": false,
          "published_at": "2026-08-09T12:00:00Z",
          "assets": [{"name": "Localmem.dmg", "browser_download_url": "https://example.invalid/Localmem.dmg"}]
        }]
        """.data(using: .utf8)!

        let releases = try JSONDecoder().decode([GitHubReleaseInfo].self, from: json)
        #expect(releases.count == 1)
        #expect(releases[0].cleanVersion == "1.1.0")
        #expect(releases[0].dmgDownloadUrl == "https://example.invalid/Localmem.dmg")
        #expect(releases[0].flagsSecurityFix)
    }
}

@Suite struct DiskImageMountTests {

    /// Shape of real `hdiutil attach -plist` output, trimmed to the keys we read.
    private func plist(mountPoints: [String?]) -> Data {
        let entities = mountPoints.map { mp -> [String: Any] in
            var dict: [String: Any] = ["dev-entry": "/dev/disk4"]
            if let mp { dict["mount-point"] = mp }
            return dict
        }
        return try! PropertyListSerialization.data(
            fromPropertyList: ["system-entities": entities],
            format: .xml, options: 0)
    }

    @Test func readsTheMountPoint() {
        #expect(DiskImageMount.mountPoint(fromPlist: plist(mountPoints: ["/Volumes/Localmem"]))
                == "/Volumes/Localmem")
    }

    /// The case that motivated reading the plist at all: a leftover volume from
    /// an earlier attempt pushes macOS to a suffixed path, and a hardcoded
    /// `/Volumes/Localmem` would send the user to the *previous* version.
    @Test func readsASuffixedMountPointFromAStaleVolume() {
        #expect(DiskImageMount.mountPoint(fromPlist: plist(mountPoints: ["/Volumes/Localmem 1"]))
                == "/Volumes/Localmem 1")
    }

    /// hdiutil lists the whole-disk entity (no mount point) alongside the
    /// mounted partition; the first entry with a mount point is the one wanted.
    @Test func skipsEntitiesWithoutAMountPoint() {
        #expect(DiskImageMount.mountPoint(fromPlist: plist(mountPoints: [nil, "/Volumes/Localmem"]))
                == "/Volumes/Localmem")
    }

    @Test func returnsNilWhenNothingMounted() {
        #expect(DiskImageMount.mountPoint(fromPlist: plist(mountPoints: [nil])) == nil)
        #expect(DiskImageMount.mountPoint(fromPlist: plist(mountPoints: [])) == nil)
    }

    @Test func returnsNilOnGarbage() {
        #expect(DiskImageMount.mountPoint(fromPlist: Data("not a plist".utf8)) == nil)
        #expect(DiskImageMount.mountPoint(fromPlist: Data()) == nil)
    }
}
