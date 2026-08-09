import Foundation
import SwiftUI
import AppKit
import LocalmemCore

/// Release info parsed from GitHub Releases API (§12 of Technical Design).
public struct GitHubReleaseInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var tagName: String
    public var name: String?
    public var body: String?
    public var htmlUrl: String
    public var draft: Bool
    public var prerelease: Bool
    public var publishedAt: String?
    public var assets: [GitHubAsset]?

    public struct GitHubAsset: Codable, Equatable, Sendable {
        public var name: String
        public var browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }

    /// Clean semver string without leading 'v'
    public var cleanVersion: String {
        var str = tagName
        if str.lowercased().hasPrefix("v") {
            str = String(str.dropFirst())
        }
        return str
    }

    /// Finds the DMG asset download URL if present.
    public var dmgDownloadUrl: String? {
        assets?.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadUrl
    }
}

/// Manager for app version display and update checking (§12 of Technical Design).
@Observable @MainActor
public final class UpdateChecker {
    public static let shared = UpdateChecker()

    public enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate(lastChecked: Date)
        case updateAvailable(release: GitHubReleaseInfo, isSecurityFix: Bool)
        case failed(message: String)
    }

    @ObservationIgnored @AppStorage("autoCheckForUpdates") public var autoCheckForUpdates: Bool = true
    @ObservationIgnored @AppStorage("lastUpdateCheckTimestamp") private var lastUpdateCheckTimestamp: Double = 0

    public var status: Status = .idle
    public var showUpdateModal: Bool = false
    public var userInitiatedMessage: String? = nil

    public var currentVersion: String {
        LocalmemVersion.current
    }

    private let releasesAPI = "https://api.github.com/repos/localmemai/localmem-app/releases"

    public init() {}

    public func checkOnLaunchIfDue() async {
        guard autoCheckForUpdates else { return }
        let now = Date().timeIntervalSince1970
        let oneDay: TimeInterval = 86400
        if now - lastUpdateCheckTimestamp > oneDay {
            await checkForUpdates(userInitiated: false)
        }
    }

    public func checkForUpdates(userInitiated: Bool = false) async {
        status = .checking
        userInitiatedMessage = nil
        lastUpdateCheckTimestamp = Date().timeIntervalSince1970

        do {
            guard let url = URL(string: releasesAPI) else {
                status = .failed(message: "Invalid URL")
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Localmem/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                status = .failed(message: "Check failed")
                if userInitiated { userInitiatedMessage = "Failed to fetch update info." }
                return
            }

            let releases = try JSONDecoder().decode([GitHubReleaseInfo].self, from: data)

            // Filter non-draft and non-prerelease
            let stableReleases = releases.filter { !$0.draft && !$0.prerelease }

            // Find newer releases
            let newerReleases = stableReleases.filter { release in
                SemVerComparer.compare(release.cleanVersion, currentVersion) == .orderedDescending
            }

            if let latest = newerReleases.first {
                // Check if any intervening release notes mention security fixes
                let hasSecurity = newerReleases.contains { rel in
                    let text = (rel.body ?? "")
                    return text.localizedCaseInsensitiveContains("## security") ||
                           text.localizedCaseInsensitiveContains("security fix") ||
                           text.localizedCaseInsensitiveContains("[security]")
                }
                status = .updateAvailable(release: latest, isSecurityFix: hasSecurity)
                if userInitiated {
                    showUpdateModal = true
                }
            } else {
                status = .upToDate(lastChecked: Date())
                if userInitiated {
                    userInitiatedMessage = "Localmem \(currentVersion) is up to date."
                }
            }
        } catch {
            status = .failed(message: "Check failed")
            if userInitiated {
                userInitiatedMessage = "Could not check for updates. Check internet connection."
            }
        }
    }

    public func openReleasePage(_ release: GitHubReleaseInfo) {
        if let url = URL(string: release.htmlUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    public func downloadUpdate(_ release: GitHubReleaseInfo) {
        if let dmgStr = release.dmgDownloadUrl, let url = URL(string: dmgStr) {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: release.htmlUrl) {
            NSWorkspace.shared.open(url)
        }
    }
}

public struct UpdateModalView: View {
    public let release: GitHubReleaseInfo
    public let isSecurityFix: Bool
    @Environment(\.dismiss) private var dismiss

    public init(release: GitHubReleaseInfo, isSecurityFix: Bool) {
        self.release = release
        self.isSecurityFix = isSecurityFix
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: isSecurityFix ? "shield.alert.fill" : "arrow.down.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(isSecurityFix ? .red : .accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Localmem \(release.cleanVersion) Available")
                        .font(.headline)
                    if isSecurityFix {
                        Text("Security Update Available")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    } else {
                        Text("A new version of Localmem is ready for download")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(body)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            Text("Memories in your vault are stored outside the app bundle and remain completely safe during app updates.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Later") {
                    dismiss()
                }
                Spacer()
                Button("Download Update") {
                    UpdateChecker.shared.downloadUpdate(release)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
