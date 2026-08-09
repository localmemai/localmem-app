import Foundation

/// Release info parsed from the GitHub Releases API (§12 of Technical Design).
///
/// Lives in `LocalmemCore` rather than beside the checker in the app target
/// because the app has no test target: anything left there — which release to
/// offer, whether a fix was security-relevant, which asset to download — could
/// only be verified by running the app against a live API.
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

        public init(name: String, browserDownloadUrl: String) {
            self.name = name
            self.browserDownloadUrl = browserDownloadUrl
        }

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

    public init(id: Int, tagName: String, name: String? = nil, body: String? = nil,
                htmlUrl: String = "", draft: Bool = false, prerelease: Bool = false,
                publishedAt: String? = nil, assets: [GitHubAsset]? = nil) {
        self.id = id
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlUrl = htmlUrl
        self.draft = draft
        self.prerelease = prerelease
        self.publishedAt = publishedAt
        self.assets = assets
    }

    /// Clean semver string without leading 'v'.
    public var cleanVersion: String {
        var str = tagName
        if str.lowercased().hasPrefix("v") {
            str = String(str.dropFirst())
        }
        return str
    }

    /// The DMG asset's download URL, if the release published one.
    public var dmgDownloadUrl: String? {
        assets?.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadUrl
    }

    /// True when the notes carry the `## Security` heading (or an explicit
    /// `[security]` marker) that `RELEASING.md` requires for a security-relevant
    /// release. Nothing in the GitHub API reports this, so it is a convention.
    ///
    /// Deliberately *not* a bare "security fix" substring match: notes reading
    /// "contains no security fixes" would otherwise raise the warning.
    public var flagsSecurityFix: Bool {
        guard let body else { return false }
        return body.localizedCaseInsensitiveContains("## security")
            || body.localizedCaseInsensitiveContains("[security]")
    }
}

/// Decides what to offer the user, given the raw release list and the running
/// version. Pure — no networking, no UI, no file system.
public enum UpdateDecision {
    public struct Outcome: Equatable, Sendable {
        /// The release to offer, or nil when the running version is current.
        public let latest: GitHubReleaseInfo?
        /// True when *any* release between the running version and `latest`
        /// flagged a security fix.
        public let hasSecurityFix: Bool
    }

    public static func evaluate(releases: [GitHubReleaseInfo],
                                currentVersion: String) -> Outcome {
        let stable = releases.filter { !$0.draft && !$0.prerelease }
        let newer = stable.filter {
            SemVerComparer.compare($0.cleanVersion, currentVersion) == .orderedDescending
        }
        // Highest version, not first-listed: GitHub orders by creation date, so
        // a 1.0.2 backport published after 1.1.0 would otherwise be offered as
        // though it superseded it.
        let latest = newer.max {
            SemVerComparer.compare($0.cleanVersion, $1.cleanVersion) == .orderedAscending
        }
        // Scan every intervening release, not just the newest: a fix shipped in
        // 1.1.0 still matters to someone going 1.0.1 → 1.3.0.
        return Outcome(latest: latest,
                       hasSecurityFix: newer.contains(where: \.flagsSecurityFix))
    }
}

/// Parsing for `hdiutil attach -plist` output.
public enum DiskImageMount {
    /// The volume path the image actually mounted at.
    ///
    /// Never assume `/Volumes/<name>`: when a volume of that name is already
    /// mounted — a leftover from an earlier update attempt — macOS mounts at
    /// `/Volumes/<name> 1`, and a hardcoded path sends the user to drag from
    /// the *previous* version's volume.
    public static func mountPoint(fromPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }
}
