import Foundation

enum BinaryLocator {
    /// Returns the absolute path of the localmem-mcp binary that should be
    /// registered with MCP clients. `localmem-mcp` always travels co-located with
    /// `localmem`, so it lives as a sibling of the running executable.
    ///
    /// Two co-location shapes must both resolve, and both must yield a path that
    /// survives updates (clients store this absolute path; if it later moves,
    /// every registration silently breaks):
    ///
    /// - **Both binaries side by side** — dev builds (`.build/release/`) and a
    ///   Homebrew prefix (`/opt/homebrew/bin/` symlinks *both* `localmem` and
    ///   `localmem-mcp`). Here the sibling exists next to the *unresolved*
    ///   executable path, which is the stable, non-versioned location — so we
    ///   must NOT resolve symlinks (that would bake Homebrew's versioned Cellar
    ///   path into configs and break it on `brew upgrade`).
    /// - **Only `localmem` is symlinked** — the app bundles all three binaries in
    ///   `Localmem.app/Contents/MacOS/` and symlinks just `localmem` onto PATH.
    ///   The sibling doesn't exist next to the symlink, so we resolve the symlink
    ///   to the real binary inside the bundle and take its sibling. That bundle
    ///   path is itself stable across updates (the app stays in /Applications).
    ///
    /// Preferring the unresolved sibling first keeps both cases update-stable.
    static func mcpServerPath() throws -> String {
        guard let executablePath = Bundle.main.executablePath else {
            throw SetupError.cannotLocateBinary(reason: "Bundle.main.executablePath is nil")
        }
        return try resolveMCPPath(fromExecutable: executablePath)
    }

    /// Pure resolution used by `mcpServerPath()`, split out so both co-location
    /// shapes can be tested without depending on `Bundle.main`.
    static func resolveMCPPath(
        fromExecutable executablePath: String,
        fileManager: FileManager = .default
    ) throws -> String {
        let unresolved = siblingMCP(of: URL(fileURLWithPath: executablePath))
        if fileManager.isExecutableFile(atPath: unresolved.path) {
            return unresolved.path
        }

        // Executable was reached via a symlink (e.g. the app-installed CLI) whose
        // sibling mcp lives at the real target location, not next to the link.
        let resolved = siblingMCP(of: URL(fileURLWithPath: executablePath).resolvingSymlinksInPath())
        if fileManager.isExecutableFile(atPath: resolved.path) {
            return resolved.path
        }

        throw SetupError.cannotLocateBinary(
            reason: "no localmem-mcp next to \(unresolved.path) or \(resolved.path) "
                + "(build with `swift build -c release` first)"
        )
    }

    private static func siblingMCP(of executable: URL) -> URL {
        executable.deletingLastPathComponent().appendingPathComponent("localmem-mcp")
    }
}

enum SetupError: Error, CustomStringConvertible {
    case cannotLocateBinary(reason: String)
    case cliNotSupported(client: String)

    var description: String {
        switch self {
        case .cannotLocateBinary(let reason):
            return "Cannot locate localmem-mcp binary: \(reason)"
        case .cliNotSupported(let client):
            return "\(client) has no CLI-based registration path"
        }
    }
}
