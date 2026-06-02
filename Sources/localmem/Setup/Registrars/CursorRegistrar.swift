import Foundation

struct CursorRegistrar: ClientRegistrar {
    let displayName = "Cursor"
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    private var configURL: URL {
        homeDirectory.appendingPathComponent(".cursor/mcp.json")
    }

    /// Permissions file is separate from `mcp.json`. If this file exists with
    /// `mcpAllowlist`, Cursor stops honoring its in-app allowlist UI.
    private var permissionsURL: URL {
        homeDirectory.appendingPathComponent(".cursor/permissions.json")
    }

    private var cursorDir: URL {
        homeDirectory.appendingPathComponent(".cursor")
    }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: cursorDir.path)
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
    // Writes explicit `localmem:<tool>` entries to `mcpAllowlist` in
    // ~/.cursor/permissions.json. Cursor's allowlist has known intermittent
    // bugs (forum, GitHub) — best-effort, surfaced in setup output.

    func preauthorize(tools: [String]) throws -> PreauthorizationOutcome {
        let entries = tools.map { "localmem:\($0)" }
        let requested = Set(entries)
        var previouslyAuthorized: Set<String> = []
        let changed = try JSONConfig.update(at: permissionsURL) { current in
            var next = current
            let existing = (next["mcpAllowlist"] as? [String]) ?? []
            previouslyAuthorized = Set(existing).intersection(requested)
            let merged = Array(Set(existing).union(requested)).sorted()
            next["mcpAllowlist"] = merged
            return next
        }
        if !changed { return .alreadyAuthorized(scope: .tools(count: tools.count)) }
        return previouslyAuthorized.isEmpty
            ? .authorized(scope: .tools(count: tools.count))
            : .updated(scope: .tools(count: tools.count))
    }

    func preauthorizationState(tools: [String]) -> PreauthorizationState {
        let entries = Set(tools.map { "localmem:\($0)" })
        guard FileManager.default.fileExists(atPath: permissionsURL.path),
              let data = try? Data(contentsOf: permissionsURL),
              !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let approved = root["mcpAllowlist"] as? [String]
        else { return .notAuthorized }
        let missing = entries.subtracting(approved).count
        if missing == 0 { return .authorized }
        if missing == entries.count { return .notAuthorized }
        return .partial(missing: missing)
    }
}
