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
    // Server-wide `trust: true` is the only working mechanism. Acceptable
    // because every tool currently on this server is non-destructive; revisit
    // when `memory_delete` ships (resolved §8 — not preemptively).
    //
    // `tools` is ignored — this client only supports server-wide trust.

    func preauthorize(tools _: [String]) throws -> PreauthorizationOutcome {
        var wasTrusted = false
        let changed = try JSONConfig.update(at: configURL) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            var entry = (servers["localmem"] as? [String: Any]) ?? [:]
            wasTrusted = (entry["trust"] as? Bool) == true
            entry["trust"] = true
            servers["localmem"] = entry
            next["mcpServers"] = servers
            return next
        }
        if !changed { return .alreadyAuthorized(scope: .server) }
        return wasTrusted ? .alreadyAuthorized(scope: .server) : .authorized(scope: .server)
    }

    func preauthorizationState(tools _: [String]) -> PreauthorizationState {
        guard let entry = JSONConfig.readMcpEntry(at: configURL, serverName: "localmem")
        else { return .notAuthorized }
        return (entry["trust"] as? Bool) == true ? .authorized : .notAuthorized
    }
}
