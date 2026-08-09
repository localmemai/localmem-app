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

/// Manager for app version display, update checking, and assisted download (§12 of Technical Design).
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

    // Assisted download state
    public var isDownloading: Bool = false
    public var downloadProgress: Double = 0.0
    public var isReadyToInstall: Bool = false
    public var mountedVolumePath: String? = nil
    public var downloadError: String? = nil

    public var currentVersion: String {
        LocalmemVersion.current
    }

    private let releasesAPI = "https://api.github.com/repos/localmemai/localmem-app/releases"

    public init() {}

    public func checkOnLaunchIfDue() async {
        guard autoCheckForUpdates else { return }
        // Run quiet async update check on launch
        await checkForUpdates(userInitiated: false)
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

    public func downloadAndPrepareUpdate(_ release: GitHubReleaseInfo) async {
        guard let dmgUrlStr = release.dmgDownloadUrl, let downloadURL = URL(string: dmgUrlStr) else {
            // Fallback: open release page if no direct DMG asset exists
            openReleasePage(release)
            return
        }

        isDownloading = true
        downloadProgress = 0.1
        downloadError = nil

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "UpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to download update image."])
            }

            downloadProgress = 0.8

            // Copy to temporary file with .dmg extension
            let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Localmem-\(release.cleanVersion).dmg")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)

            // Gatekeeper check: spctl -a -t open --context context:primary-signature <path>
            let verifyProcess = Process()
            verifyProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
            verifyProcess.arguments = ["-a", "-t", "open", "--context", "context:primary-signature", destination.path]
            try? verifyProcess.run()
            verifyProcess.waitUntilExit()

            // Mount DMG via hdiutil
            let mountProcess = Process()
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            mountProcess.arguments = ["attach", destination.path, "-nobrowse"]
            try? mountProcess.run()
            mountProcess.waitUntilExit()

            downloadProgress = 1.0
            isDownloading = false
            isReadyToInstall = true
            mountedVolumePath = "/Volumes/Localmem"
        } catch {
            isDownloading = false
            downloadError = "Download failed: \(error.localizedDescription)"
        }
    }

    public func openReleasePage(_ release: GitHubReleaseInfo) {
        if let url = URL(string: release.htmlUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    public func quitAndInstall() {
        if let mountPath = mountedVolumePath, FileManager.default.fileExists(atPath: mountPath) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mountPath)
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            if let downloads {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: downloads.path)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.terminate(nil)
            exit(0)
        }
    }
}

public struct UpdateModalView: View {
    public let release: GitHubReleaseInfo
    public let isSecurityFix: Bool
    @State private var checker = UpdateChecker.shared
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
                    .foregroundStyle(isSecurityFix ? .red : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(checker.isReadyToInstall ? "Ready to Install Localmem \(release.cleanVersion)" : "Localmem \(release.cleanVersion) Available")
                        .font(.headline)
                    if isSecurityFix {
                        Text("Security Update Available")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    } else if checker.isReadyToInstall {
                        Text("Update image downloaded and mounted.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("A new version of Localmem is ready for download.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            if checker.isDownloading {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading update image…")
                        .font(.subheadline.weight(.medium))
                    ProgressView(value: checker.downloadProgress)
                        .progressViewStyle(.linear)
                }
                .padding(.vertical, 8)
            } else if checker.isReadyToInstall {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Steps to complete update:")
                        .font(.subheadline.weight(.semibold))
                    Text("1. Click **Quit and Install** below to open the disk image.")
                        .font(.caption)
                    Text("2. Drag **Localmem** into your **Applications** folder to replace the old app.")
                        .font(.caption)
                    Text("3. Re-open Localmem.")
                        .font(.caption)
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            } else if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(body)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }

            if let err = checker.downloadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Memories in your vault are stored safely outside the app bundle (~/Library/Application Support/Localmem/) and remain completely intact.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(checker.isReadyToInstall ? "Cancel" : "Later") {
                    dismiss()
                }
                Spacer()
                if checker.isReadyToInstall {
                    Button("Quit and Install") {
                        checker.quitAndInstall()
                    }
                    .buttonStyle(.borderedProminent)
                } else if checker.isDownloading {
                    Button("Downloading…") {}
                        .disabled(true)
                } else {
                    Button("Download Update") {
                        Task {
                            await checker.downloadAndPrepareUpdate(release)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
