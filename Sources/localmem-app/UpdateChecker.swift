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

    /// True when the notes carry the `## Security` heading (or an explicit
    /// `[security]` marker) that the release checklist requires for a
    /// security-relevant release. Nothing in the GitHub API reports this, so it
    /// is a convention — see §12. Deliberately *not* a bare "security fix"
    /// substring match: "contains no security fixes" would trip it.
    public var flagsSecurityFix: Bool {
        guard let body else { return false }
        return body.localizedCaseInsensitiveContains("## security")
            || body.localizedCaseInsensitiveContains("[security]")
    }
}

/// Runs a short-lived subprocess off the main actor and returns its exit status
/// and stdout. `UpdateChecker` is `@MainActor`, and `waitUntilExit()` blocks the
/// calling thread — doing that inline froze the UI for the duration of both
/// `spctl` and `hdiutil`.
private func runTool(_ path: String, _ arguments: [String]) async -> (status: Int32, output: Data) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, Data()))
                return
            }
            // Drain before waiting: a full pipe buffer would deadlock the child.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: (process.terminationStatus, data))
        }
    }
}

/// Forwards `URLSession` download progress. The async `download(from:delegate:)`
/// reports byte counts only through a delegate, and the alternative — moving the
/// progress bar to fixed points around an opaque call — shows a bar frozen at
/// 10% for the whole transfer.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // Required by the protocol; the async form takes delivery of the file, so
    // this is never the completion path.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
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

    /// Chosen in the setup wizard, changeable in Settings. When off, nothing
    /// here ever touches the network unless the user presses a button.
    @ObservationIgnored @AppStorage("autoCheckForUpdates") public var autoCheckForUpdates: Bool = true
    @ObservationIgnored @AppStorage("lastUpdateCheckTimestamp") private var lastUpdateCheckTimestamp: Double = 0

    /// How stale the last automatic check must be before launch triggers another.
    /// Manual checks ignore this entirely.
    private let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    /// The release the modal is showing, if any.
    ///
    /// Carried as an item rather than a `Bool` + a separate lookup into
    /// `status`: with a flag, a re-check that moved `status` off
    /// `.updateAvailable` left the sheet presented with nothing inside it and
    /// no way to dismiss it.
    public struct PendingUpdate: Identifiable, Equatable, Sendable {
        public let release: GitHubReleaseInfo
        public let isSecurityFix: Bool
        public var id: Int { release.id }
    }

    public var status: Status = .idle
    public var pendingUpdate: PendingUpdate?
    public var userInitiatedMessage: String? = nil

    // Assisted download state
    public var isDownloading: Bool = false
    public var downloadedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var isReadyToInstall: Bool = false
    public var mountedVolumePath: String? = nil
    public var downloadError: String? = nil

    /// Where the downloaded image lives, so it can be cleaned up on cancel.
    @ObservationIgnored private var downloadedImagePath: URL?

    public var downloadProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    public var currentVersion: String {
        LocalmemVersion.current
    }

    private let releasesAPI = "https://api.github.com/repos/localmemai/localmem-app/releases"

    public init() {}

    /// The automatic path: opt-in, and at most once per 24h.
    ///
    /// The caller must not invoke this before the setup wizard has had its say —
    /// `autoCheckForUpdates` defaults to `true`, so running it during first
    /// launch would fire the request before the user could decline it.
    public func checkOnLaunchIfDue() async {
        guard autoCheckForUpdates else { return }
        let elapsed = Date().timeIntervalSince1970 - lastUpdateCheckTimestamp
        guard elapsed >= automaticCheckInterval else { return }
        await checkForUpdates(userInitiated: false)
    }

    public func checkForUpdates(userInitiated: Bool = false) async {
        status = .checking
        userInitiatedMessage = nil
        lastUpdateCheckTimestamp = Date().timeIntervalSince1970
        // A prepared download belongs to the release that produced it. Leaving
        // it in place lets a later check offer 1.0.3 while "Quit and Install"
        // still points at the 1.0.2 volume mounted earlier.
        await discardPreparedUpdate()

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

            // Highest version, not first-listed: GitHub orders by creation date,
            // so a 1.0.2 backport published after 1.1.0 would otherwise win.
            let latest = newerReleases.max { a, b in
                SemVerComparer.compare(a.cleanVersion, b.cleanVersion) == .orderedAscending
            }

            if let latest {
                // Scan every intervening release, not just the newest: a fix
                // shipped in 1.1.0 still matters to someone going 1.0.1 → 1.3.0.
                let hasSecurity = newerReleases.contains(where: \.flagsSecurityFix)
                status = .updateAvailable(release: latest, isSecurityFix: hasSecurity)
                if userInitiated {
                    pendingUpdate = PendingUpdate(release: latest, isSecurityFix: hasSecurity)
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
        downloadedBytes = 0
        totalBytes = 0
        downloadError = nil

        do {
            let delegate = DownloadProgressDelegate { [weak self] written, expected in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadedBytes = written
                    self.totalBytes = expected
                }
            }
            let (tempURL, response) = try await URLSession.shared.download(from: downloadURL, delegate: delegate)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "UpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to download update image."])
            }

            // Copy to temporary file with .dmg extension
            let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Localmem-\(release.cleanVersion).dmg")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            downloadedImagePath = destination

            // Gatekeeper verdict, and it has to be *read*. We downloaded an
            // executable on the user's behalf; mounting an image that failed
            // this check while the UI says "verified" is worse than not
            // checking at all. On failure the image is destroyed and there is
            // no way to proceed.
            let verify = await runTool("/usr/sbin/spctl",
                                       ["-a", "-t", "open", "--context", "context:primary-signature", destination.path])
            guard verify.status == 0 else {
                try? FileManager.default.removeItem(at: destination)
                downloadedImagePath = nil
                isDownloading = false
                downloadError = "The downloaded update couldn't be verified and was discarded. "
                              + "Download Localmem again from the releases page."
                return
            }

            // Mount it. No -nobrowse: the whole point is that the user drags
            // out of the volume window, so it has to be visible in Finder.
            let mount = await runTool("/usr/bin/hdiutil", ["attach", destination.path, "-plist"])
            guard mount.status == 0, let mountPoint = Self.mountPoint(fromPlist: mount.output) else {
                try? FileManager.default.removeItem(at: destination)
                downloadedImagePath = nil
                isDownloading = false
                downloadError = "The update image couldn't be opened."
                return
            }

            isDownloading = false
            isReadyToInstall = true
            // Read from hdiutil rather than assuming /Volumes/Localmem: a stale
            // mount makes macOS pick "/Volumes/Localmem 1" instead.
            mountedVolumePath = mountPoint
        } catch {
            isDownloading = false
            downloadError = "Download failed: \(error.localizedDescription)"
        }
    }

    /// Pulls the mounted volume path out of `hdiutil attach -plist` output.
    nonisolated static func mountPoint(fromPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    /// Detaches the mounted volume and deletes the downloaded image. Called when
    /// a prepared update is abandoned — on cancel, or when a fresh check
    /// supersedes it — so temp images and stray volumes don't accumulate.
    public func discardPreparedUpdate() async {
        if let path = mountedVolumePath {
            _ = await runTool("/usr/bin/hdiutil", ["detach", path, "-quiet"])
        }
        if let image = downloadedImagePath {
            try? FileManager.default.removeItem(at: image)
        }
        mountedVolumePath = nil
        downloadedImagePath = nil
        isReadyToInstall = false
        downloadError = nil
        downloadedBytes = 0
        totalBytes = 0
    }

    public func openReleasePage(_ release: GitHubReleaseInfo) {
        if let url = URL(string: release.htmlUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the mounted volume and quits. Finder refuses to replace a running
    /// app, so the app has to be gone before the user drags — which is why the
    /// modal states the steps before this runs.
    public func quitAndInstall() {
        if let mountPath = mountedVolumePath, FileManager.default.fileExists(atPath: mountPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: mountPath))
        }
        // Give Finder a beat to come forward, then hand over to the normal
        // termination path — no exit(0), which would skip it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}

public struct UpdateModalView: View {
    public let release: GitHubReleaseInfo
    public let isSecurityFix: Bool
    private let checker = UpdateChecker.shared
    @Environment(\.dismiss) private var dismiss

    public init(release: GitHubReleaseInfo, isSecurityFix: Bool) {
        self.release = release
        self.isSecurityFix = isSecurityFix
    }

    private var progressLabel: String {
        guard checker.totalBytes > 0 else { return "Downloading update image…" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: checker.downloadedBytes)
        let total = formatter.string(fromByteCount: checker.totalBytes)
        return "Downloading… \(done) of \(total)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: isSecurityFix ? "shield.lefthalf.filled" : "arrow.down.circle.fill")
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
                        Text("Update image downloaded and verified.")
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
                    Text(progressLabel)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    if checker.totalBytes > 0 {
                        ProgressView(value: checker.downloadProgress)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .padding(.vertical, 8)
            } else if checker.isReadyToInstall {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Localmem needs to quit before it can be replaced.")
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
                    // Abandoning a prepared update unmounts it and deletes the
                    // image, so the next check starts from nothing.
                    Task { await checker.discardPreparedUpdate() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if checker.isReadyToInstall {
                    Button("Quit and Install") {
                        checker.quitAndInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
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
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
