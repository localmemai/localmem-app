import Foundation

/// The single source of truth for Localmem's version, shared by all three
/// binaries (`localmem --version`, the MCP server's `initialize` response,
/// and anywhere else a version string is needed).
///
/// **Release checklist:** bump this to match the release tag. The release
/// workflow fails fast if the tag (`vX.Y.Z`) doesn't equal this string, so
/// the MCP/CLI version can never silently drift from the released app again
/// (it sat at "0.1.0" for three releases before this existed).
public enum LocalmemVersion {
    public static let current = "1.0.0"
}
