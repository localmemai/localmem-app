import Foundation

struct ClaudeCodeRegistrar: ClientRegistrar {
    let displayName = "Claude Code"
    let cliCommand: String? = "claude"
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    private var configURL: URL {
        homeDirectory.appendingPathComponent(".claude.json")
    }

    /// Permission file is separate from `.claude.json` registration file.
    private var settingsURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    func isInstalled() -> Bool {
        // Either the CLI is on PATH or the user has a Claude Code config dir/file.
        ShellHelper.commandExists("claude")
            || FileManager.default.fileExists(atPath: configURL.path)
            || FileManager.default.fileExists(atPath: homeDirectory
                .appendingPathComponent(".claude").path)
    }

    // MARK: - CLI path

    func registerViaCLI(binaryPath: String) throws -> RegistrationOutcome {
        let list = try ShellHelper.run("claude", ["mcp", "list"])
        // Match `localmem` as a whole entry, not any line that happens to
        // contain the substring (e.g. another server called `localmem-staging`).
        let registered = list.stdout.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "localmem"
                || trimmed.hasPrefix("localmem ")
                || trimmed.hasPrefix("localmem:")
        }
        let pointsAtUs = list.stdout.contains(binaryPath)

        if registered && pointsAtUs { return .alreadyRegistered(via: .cli) }
        if registered {
            _ = try? ShellHelper.run("claude", ["mcp", "remove", "localmem"])
            try ShellHelper.runOrThrow("claude", ["mcp", "add", "localmem", binaryPath, "--scope", "user"])
            return .updated(via: .cli)
        }
        try ShellHelper.runOrThrow("claude", ["mcp", "add", "localmem", binaryPath, "--scope", "user"])
        return .registered(via: .cli)
    }

    // MARK: - File path

    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
        var previous: [String: Any]?
        let changed = try JSONConfig.update(at: configURL) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            previous = servers["localmem"] as? [String: Any]
            servers["localmem"] = ["command": binaryPath]
            next["mcpServers"] = servers
            return next
        }
        if !changed { return .alreadyRegistered(via: .configFile) }
        return previous == nil ? .registered(via: .configFile) : .updated(via: .configFile)
    }

    // MARK: - Status

    func isRegistered() -> Bool {
        JSONConfig.readMcpEntry(at: configURL, serverName: "localmem") != nil
    }

    func registeredBinaryPath() -> String? {
        JSONConfig.readMcpEntry(at: configURL, serverName: "localmem")?["command"] as? String
    }

    // MARK: - Pre-authorization
    //
    // Writes explicit per-tool entries under `permissions.allow` in
    // ~/.claude/settings.json (user scope). Each tool becomes
    // `mcp__localmem__<tool>`. Wildcards exist but have known reliability
    // bugs — explicit names always work.

    func preauthorize(tools: [String]) throws -> PreauthorizationOutcome {
        let entries = tools.map { "mcp__localmem__\($0)" }
        let requested = Set(entries)
        var previouslyAuthorized: Set<String> = []
        let changed = try JSONConfig.update(at: settingsURL) { current in
            var next = current
            var permissions = (next["permissions"] as? [String: Any]) ?? [:]
            let existing = (permissions["allow"] as? [String]) ?? []
            previouslyAuthorized = Set(existing).intersection(requested)
            let merged = Array(Set(existing).union(requested)).sorted()
            permissions["allow"] = merged
            next["permissions"] = permissions
            return next
        }
        if !changed { return .alreadyAuthorized(scope: .tools(count: tools.count)) }
        return previouslyAuthorized.isEmpty
            ? .authorized(scope: .tools(count: tools.count))
            : .updated(scope: .tools(count: tools.count))
    }

    func preauthorizationState(tools: [String]) -> PreauthorizationState {
        let entries = Set(tools.map { "mcp__localmem__\($0)" })
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = root["permissions"] as? [String: Any],
              let approved = permissions["allow"] as? [String]
        else { return .notAuthorized }
        let missing = entries.subtracting(approved).count
        if missing == 0 { return .authorized }
        if missing == entries.count { return .notAuthorized }
        return .partial(missing: missing)
    }
}
