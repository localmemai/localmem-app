import Foundation
import SwiftUI
import AppKit
import LocalmemCore

// `GitHubReleaseInfo`, `UpdateDecision`, and `DiskImageMount` live in
// LocalmemCore — the app target has no tests, and those are the parts with
// decisions worth verifying. See `Sources/LocalmemCore/UpdateRelease.swift`.

/// Runs a short-lived subprocess off the main actor and returns its exit status
/// and stdout. `UpdateChecker` is `@MainActor`, and `waitUntilExit()` blocks the
/// calling thread — doing that inline froze the UI for the duration of both
/// `spctl` and `hdiutil`.
private func runTool(_ path: String, _ arguments: [String]) async -> (status: Int32, output: Data, errorText: String) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, Data(), ""))
                return
            }
            // Drain both before waiting: a full pipe buffer would deadlock the
            // child. stderr is kept separate rather than merged because
            // `hdiutil -plist` output has to stay parseable, while `codesign -d`
            // reports everything we need on stderr.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: (process.terminationStatus, data,
                                            String(decoding: errData, as: UTF8.self)))
        }
    }
}

/// The Team ID the running copy of Localmem is signed with, or nil when it is
/// unsigned — a local `swift run` build, typically.
///
/// Used to pin update verification to *our own* identity rather than a
/// hardcoded constant: notarization proves an image came from *an* Apple
/// developer, not from us. Deriving it this way also means a fork signed with a
/// different certificate pins to itself without editing any code.
private func runningTeamIdentifier() async -> String? {
    let result = await runTool("/usr/bin/codesign",
                               ["-d", "--verbose=4", Bundle.main.bundlePath])
    guard result.status == 0 else { return nil }
    for line in result.errorText.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
        let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
        return (value.isEmpty || value == "not set") ? nil : value
    }
    return nil
}

/// Hosts a release asset may be fetched from.
///
/// `browser_download_url` arrives from the API response, so treating it as a
/// trusted URL means whoever can influence that JSON chooses where the app
/// downloads an executable from.
private let allowedDownloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com"]

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
        case upToDate
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
            let outcome = UpdateDecision.evaluate(releases: releases, currentVersion: currentVersion)

            if let latest = outcome.latest {
                status = .updateAvailable(release: latest, isSecurityFix: outcome.hasSecurityFix)
                if userInitiated {
                    pendingUpdate = PendingUpdate(release: latest, isSecurityFix: outcome.hasSecurityFix)
                }
            } else {
                status = .upToDate
                if userInitiated {
                    userInitiatedMessage = "Localmem \(currentVersion) is the latest version."
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
        // Where the asset lives is not the release JSON's decision to make.
        guard downloadURL.scheme == "https",
              let host = downloadURL.host, allowedDownloadHosts.contains(host) else {
            downloadError = "This release points its download somewhere unexpected. "
                          + "Download Localmem from the releases page instead."
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
            // `spctl` answers "is this signed and notarized", not "by whom".
            // Any image from any Apple developer account passes it, so pin the
            // identity too — otherwise an attacker who can influence the
            // release JSON supplies their own notarized image and the UI calls
            // it verified. Skipped only when we cannot read our own Team ID,
            // i.e. an unsigned local build, where there is nothing to pin to.
            if let teamID = await runningTeamIdentifier() {
                let requirement = "anchor apple generic and certificate leaf[subject.OU] = \(teamID)"
                let pinned = await runTool("/usr/bin/codesign",
                                           ["--verify", "-R", "=\(requirement)", destination.path])
                guard pinned.status == 0 else {
                    try? FileManager.default.removeItem(at: destination)
                    downloadedImagePath = nil
                    isDownloading = false
                    downloadError = "The downloaded update is not signed by Localmem and was discarded. "
                                  + "Download Localmem again from the releases page."
                    return
                }
            }

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
            guard mount.status == 0, let mountPoint = DiskImageMount.mountPoint(fromPlist: mount.output) else {
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
