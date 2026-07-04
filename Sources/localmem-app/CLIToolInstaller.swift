import Foundation

// MARK: - Command-line tool installer
//
// The app bundles the `localmem` CLI alongside the GUI in Contents/MacOS. This
// puts it on the user's PATH by symlinking it into /usr/local/bin — the VS Code
// `code` / Ollama pattern.
//
// We deliberately install a *symlink*, not a copy. The CLI must resolve its
// sibling `localmem-mcp` back inside the app bundle (see BinaryLocator), and an
// in-place app update automatically refreshes what the symlink points at. The
// link target — /Applications/Localmem.app/... — is versionless and stable, so
// registrations that `localmem setup` writes keep working across updates.
//
// Nothing here touches user data: memories and instruction files live outside
// the bundle and are never involved.

enum CLIToolInstaller {
    /// Where the symlink is created. Standard PATH location for hand-installed
    /// developer tools.
    static let linkPath = "/usr/local/bin/localmem"

    enum Status: Equatable {
        /// No `localmem` on PATH at the link location yet.
        case notInstalled
        /// Installed and pointing at *this* app's bundled CLI.
        case installed
        /// A `localmem` exists at the link location but resolves elsewhere
        /// (a Homebrew install, or an older/other app). Carries the resolved path.
        case conflict(String)
        /// This build has no bundled CLI to install (should not happen in a
        /// packaged app; possible in some dev layouts).
        case unavailable
    }

    /// The bundled `localmem` binary — a sibling of the running GUI executable.
    static var bundledCLI: URL? {
        guard let exe = Bundle.main.executablePath else { return nil }
        let candidate = URL(fileURLWithPath: exe)
            .deletingLastPathComponent()
            .appendingPathComponent("localmem")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static func status() -> Status {
        guard let source = bundledCLI else { return .unavailable }
        let fm = FileManager.default
        guard fm.fileExists(atPath: linkPath) else { return .notInstalled }

        // Resolve whatever is at the link location and compare to our bundled CLI.
        let resolved = URL(fileURLWithPath: linkPath).resolvingSymlinksInPath().path
        return resolved == source.resolvingSymlinksInPath().path
            ? .installed
            : .conflict(resolved)
    }

    /// Create (or replace) the symlink at `linkPath` pointing at the bundled CLI.
    ///
    /// /usr/local/bin is root-owned on a stock Mac, so this shells out through
    /// osascript with administrator privileges — the OS shows the standard
    /// authorization prompt. Throws `CLIToolInstallError` on failure or if the
    /// user cancels the prompt.
    static func install() throws {
        guard let source = bundledCLI else { throw CLIToolInstallError.noBundledCLI }

        // Try a direct symlink first (works if the user already owns /usr/local/bin,
        // e.g. after Homebrew set it up) to avoid an unnecessary auth prompt.
        let fm = FileManager.default
        if fm.isWritableFile(atPath: "/usr/local/bin") || !fm.fileExists(atPath: "/usr/local/bin") {
            do {
                try linkDirectly(source: source)
                return
            } catch {
                // Fall through to the privileged path.
            }
        }
        try linkWithPrivileges(source: source)
    }

    /// Remove the symlink if it points at us. No-op otherwise.
    static func uninstall() throws {
        guard case .installed = status() else { return }
        let script = "rm -f \(shellQuote(linkPath))"
        try runPrivileged(script)
    }

    // MARK: - Mechanics

    private static func linkDirectly(source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
        if fm.fileExists(atPath: linkPath) { try fm.removeItem(atPath: linkPath) }
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: source.path)
    }

    private static func linkWithPrivileges(source: URL) throws {
        let script = "mkdir -p /usr/local/bin && ln -sf \(shellQuote(source.path)) \(shellQuote(linkPath))"
        try runPrivileged(script)
    }

    /// Run a shell one-liner as administrator via osascript. Surfaces a clean
    /// error if the user cancels (osascript exits non-zero with -128).
    private static func runPrivileged(_ shellScript: String) throws {
        let osa = "do shell script \"\(escapeForAppleScript(shellScript))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", osa]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if stderr.contains("-128") || stderr.contains("User canceled") {
                throw CLIToolInstallError.cancelled
            }
            throw CLIToolInstallError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a shell string for embedding inside an AppleScript string literal.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum CLIToolInstallError: LocalizedError {
    case noBundledCLI
    case cancelled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBundledCLI:            return "This build has no bundled command-line tool to install."
        case .cancelled:               return "Authorization was cancelled."
        case .commandFailed(let why):  return why.isEmpty ? "Could not install the command-line tool." : why
        }
    }
}
