import Foundation

struct ClaudeCodeRegistrar: ClientRegistrar {
    let displayName = "Claude Code"
    let cliCommand: String? = "claude"

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    func isInstalled() -> Bool {
        // Either the CLI is on PATH or the user has a Claude Code config dir/file.
        ShellHelper.commandExists("claude")
            || FileManager.default.fileExists(atPath: configURL.path)
            || FileManager.default.fileExists(atPath: FileManager.default
                .homeDirectoryForCurrentUser
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
}
