import Foundation

/// One agent's instruction-file target.
public struct AgentInstructionTarget: Sendable {
    public let displayName: String
    /// Relative to the home directory (no leading slash). e.g. ".claude/CLAUDE.md".
    public let relativePath: String

    public init(displayName: String, relativePath: String) {
        self.displayName = displayName
        self.relativePath = relativePath
    }
}

public enum InstallationOutcome: Sendable {
    case created           // file did not exist; created with import line
    case imported          // file existed; import line appended
    case alreadyImported   // import line already present (no-op)
    case skipped(reason: String)
}

public enum InstructionRemovalOutcome: Sendable {
    case removed
    case alreadyAbsent
    case skipped(reason: String)
}

public enum InstructionsInstallError: Error, Sendable {
    case canonicalWriteFailed(URL, underlying: Error)
    case targetWriteFailed(URL, underlying: Error)
}

/// Writes the bundled `AGENTS.md` to `~/.localmem/AGENTS.md` and injects a
/// single import line into each agent's instruction file.
///
/// Idempotent: re-running on a clean install is a no-op for every target.
/// The canonical file at `~/.localmem/AGENTS.md` is overwritten unconditionally
/// on every run (managed-file contract — see plan §7).
public struct InstructionsInstaller: Sendable {
    public let agentsContent: String
    public let homeDir: URL

    public init(
        agentsContent: String,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.agentsContent = agentsContent
        self.homeDir = homeDir
    }

    /// Convenience: load the bundled `AGENTS.md` from `LocalmemCore`.
    public init(homeDir: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try self.init(agentsContent: AgentsResource.read(), homeDir: homeDir)
    }

    /// The set of agents whose instruction files we maintain.
    /// Order matches the SetupCommand registrar order for consistent report output.
    public static let defaultTargets: [AgentInstructionTarget] = [
        .init(displayName: "Antigravity", relativePath: ".gemini/AGENTS.md"),
        .init(displayName: "Cursor",      relativePath: ".cursor/AGENTS.md"),
        .init(displayName: "Codex",       relativePath: ".codex/AGENTS.md"),
        .init(displayName: "Claude Code", relativePath: ".claude/CLAUDE.md"),
    ]

    // MARK: - Public API

    /// Absolute URL of the canonical `~/.localmem/AGENTS.md`.
    public var canonicalURL: URL {
        homeDir.appendingPathComponent(".localmem/AGENTS.md")
    }

    /// The exact line we inject. The trailing `<!-- localmem -->` tag is the
    /// idempotency anchor — we never rewrite an existing line, we just check
    /// for the tag's presence.
    public var importLine: String {
        "@\(canonicalURL.path) <!-- localmem -->"
    }

    /// Write `~/.localmem/AGENTS.md`. Always overwrites — managed file.
    public func installCanonicalFile() throws {
        let dir = canonicalURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try agentsContent.write(to: canonicalURL, atomically: true, encoding: .utf8)
        } catch {
            throw InstructionsInstallError.canonicalWriteFailed(canonicalURL, underlying: error)
        }
    }

    /// Inject the import line into a single agent's instruction file.
    /// Skips if the agent's directory does not exist (taken as a signal that
    /// the agent isn't installed on this machine).
    public func injectImportLine(into target: AgentInstructionTarget) throws -> InstallationOutcome {
        let targetURL = homeDir.appendingPathComponent(target.relativePath)
        let parentDir = targetURL.deletingLastPathComponent()

        // Don't create the agent's config dir just to write our import.
        // If the directory doesn't exist, the agent isn't on this machine.
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            return .skipped(reason: "\(target.displayName) not installed")
        }

        let existing = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
        let fileExisted = !existing.isEmpty || FileManager.default.fileExists(atPath: targetURL.path)

        if existing.contains("<!-- localmem -->") {
            return .alreadyImported
        }

        let separator = (existing.isEmpty || existing.hasSuffix("\n")) ? "" : "\n"
        let trailingNewline = existing.isEmpty ? "\n" : ""
        let updated = existing + separator + importLine + "\n" + trailingNewline

        do {
            try updated.write(to: targetURL, atomically: true, encoding: .utf8)
        } catch {
            throw InstructionsInstallError.targetWriteFailed(targetURL, underlying: error)
        }
        return fileExisted ? .imported : .created
    }

    /// Remove Localmem's managed import line from a single agent instruction
    /// file, preserving every other line verbatim.
    public func removeImportLine(from target: AgentInstructionTarget) throws -> InstructionRemovalOutcome {
        let targetURL = homeDir.appendingPathComponent(target.relativePath)
        let parentDir = targetURL.deletingLastPathComponent()

        guard FileManager.default.fileExists(atPath: parentDir.path) else {
            return .skipped(reason: "\(target.displayName) not installed")
        }
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return .alreadyAbsent
        }

        let existing = try String(contentsOf: targetURL, encoding: .utf8)
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
        let filtered = lines.filter { !$0.contains("<!-- localmem -->") }
        guard filtered.count != lines.count else { return .alreadyAbsent }

        var updated = filtered.joined(separator: "\n")
        if existing.hasSuffix("\n") { updated += "\n" }
        do {
            try updated.write(to: targetURL, atomically: true, encoding: .utf8)
        } catch {
            throw InstructionsInstallError.targetWriteFailed(targetURL, underlying: error)
        }
        return .removed
    }

    /// Run the full install: canonical file + every target.
    /// Per-target errors are captured per row; canonical-write failure is fatal.
    public func installAll(targets: [AgentInstructionTarget] = defaultTargets) throws -> [TargetResult] {
        try installCanonicalFile()
        return targets.map { target in
            do { return .init(name: target.displayName, outcome: .success(try injectImportLine(into: target))) }
            catch { return .init(name: target.displayName, outcome: .failure(error)) }
        }
    }

    public func removeAll(targets: [AgentInstructionTarget] = defaultTargets) -> [RemovalResult] {
        targets.map { target in
            do { return .init(name: target.displayName, outcome: .success(try removeImportLine(from: target))) }
            catch { return .init(name: target.displayName, outcome: .failure(error)) }
        }
    }

    public struct TargetResult: Sendable {
        public let name: String
        public let outcome: Result<InstallationOutcome, Error>
    }

    public struct RemovalResult: Sendable {
        public let name: String
        public let outcome: Result<InstructionRemovalOutcome, Error>
    }
}
