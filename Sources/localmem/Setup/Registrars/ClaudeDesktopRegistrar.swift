import Foundation

struct ClaudeDesktopRegistrar: ClientRegistrar {
    let displayName = "Claude Desktop"
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    private var configURL: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    private var appBundle: URL {
        URL(fileURLWithPath: "/Applications/Claude.app")
    }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: appBundle.path)
            || FileManager.default.fileExists(atPath: configURL.path)
    }

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
    // Claude Desktop's community-documented pattern: `autoapprove` lives inside
    // the same `mcpServers.localmem` block we already write. Union-merge so we
    // never clobber tools a user has hand-added.

    func preauthorize(tools: [String]) throws -> PreauthorizationOutcome {
        let requested = Set(tools)
        var previouslyAuthorized: Set<String> = []
        let changed = try JSONConfig.update(at: configURL) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            var entry = (servers["localmem"] as? [String: Any]) ?? [:]
            let existing = (entry["autoapprove"] as? [String]) ?? []
            previouslyAuthorized = Set(existing).intersection(requested)
            let merged = Array(Set(existing).union(requested)).sorted()
            entry["autoapprove"] = merged
            servers["localmem"] = entry
            next["mcpServers"] = servers
            return next
        }
        if !changed { return .alreadyAuthorized(scope: .tools(count: tools.count)) }
        return previouslyAuthorized.isEmpty
            ? .authorized(scope: .tools(count: tools.count))
            : .updated(scope: .tools(count: tools.count))
    }

    func preauthorizationState(tools: [String]) -> PreauthorizationState {
        guard let entry = JSONConfig.readMcpEntry(at: configURL, serverName: "localmem"),
              let approved = entry["autoapprove"] as? [String]
        else { return .notAuthorized }
        let missing = Set(tools).subtracting(approved).count
        if missing == 0 { return .authorized }
        if missing == tools.count { return .notAuthorized }
        return .partial(missing: missing)
    }
}
