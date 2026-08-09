import Foundation

/// The single source of truth for Localmem's version, shared by all three
/// binaries (`localmem --version`, the MCP server's `initialize` response,
/// and anywhere else a version string is needed).
///
/// **Release checklist:** bump this to match the release tag. The release
/// workflow fails fast if the tag (`vX.Y.Z`) doesn't equal this string, so
/// the MCP/CLI version can never silently drift from the released app again
/// (it sat at "0.1.0" for three releases before this existed).
///
/// Also at tag time: if the release fixes a security issue, the notes need a
/// `## Security` heading. Nothing in the GitHub API reports that, so the app's
/// update check reads the heading — omit it and users are never told (§12).
/// The full checklist is in `RELEASING.md`.
public enum LocalmemVersion {
    public static let current = "1.0.1"
}

/// Component-wise semver comparison helper (§12 of Technical Design).
public enum SemVerComparer {
    public static func compare(_ v1: String, _ v2: String) -> ComparisonResult {
        let parts1 = numericComponents(of: v1)
        let parts2 = numericComponents(of: v2)

        let maxCount = max(parts1.count, parts2.count)
        for i in 0..<maxCount {
            let num1 = i < parts1.count ? parts1[i] : 0
            let num2 = i < parts2.count ? parts2[i] : 0
            if num1 < num2 { return .orderedAscending }
            if num1 > num2 { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Splits the release portion of a version into integers.
    ///
    /// Both the prerelease suffix (`-beta.1`) and the build-metadata suffix
    /// (`+build.7`) are dropped before splitting. Discarding unparsable
    /// components instead would shift the remainder left — `1.0.1+build.2`
    /// became `[1, 0, 2]`, which compares *newer* than `1.0.1`, so the app
    /// offered an update to the version already running. A non-numeric
    /// component now terminates the parse instead.
    private static func numericComponents(of version: String) -> [Int] {
        var cleaned = version.trimmingCharacters(in: .whitespaces)
        if let first = cleaned.first, first == "v" || first == "V" {
            cleaned = String(cleaned.dropFirst())
        }
        // Strip build metadata first: semver allows `1.0.0-beta+exp`, where the
        // `+` section may itself contain a `-`.
        let withoutBuild = cleaned.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let release = withoutBuild.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""

        var components: [Int] = []
        for piece in release.split(separator: ".") {
            guard let value = Int(piece) else { break }
            components.append(value)
        }
        return components
    }
}
