import Foundation

struct AntigravityRegistrar: ClientRegistrar {
    let displayName = "Antigravity"
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    private var configURL: URL {
        homeDirectory.appendingPathComponent(".gemini/config/mcp_config.json")
    }

    private var geminiDir: URL {
        homeDirectory.appendingPathComponent(".gemini")
    }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: geminiDir.path)
    }

    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
        var previous: [String: Any]?
        let changed = try JSONConfig.update(at: configURL) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            previous = servers["localmem"] as? [String: Any]
            servers["localmem"] = [
                "type": "stdio",
                "command": binaryPath,
                "args": []
            ] as [String: Any]
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
    // Per-tool `alwaysAllow` is documented but not honored as of March 2026.
    // Antigravity's only working mechanism is server-wide `trust: true` — and
    // that is all-or-nothing: it would silently auto-approve every tool on the
    // server, including `memory_update`, which is deliberately excluded from
    // pre-authorization (see `Localmem.preauthorizedToolNames`). So we never
    // write `trust` ourselves; we skip with the reason surfaced in the report.
    // A user who accepts the trade-off can still set trust manually —
    // `preauthorizationState` reports it if they did.

    func preauthorize(tools _: [String]) throws -> PreauthorizationOutcome {
        .skipped(reason: "Antigravity only supports server-wide trust, which would auto-approve memory_update")
    }

    func preauthorizationState(tools _: [String]) -> PreauthorizationState {
        guard let entry = JSONConfig.readMcpEntry(at: configURL, serverName: "localmem")
        else { return .notAuthorized }
        return (entry["trust"] as? Bool) == true ? .authorized : .notAuthorized
    }
}
