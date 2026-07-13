import Foundation
import TOMLKit

struct CodexRegistrar: ClientRegistrar {
    let displayName = "Codex"
    let cliCommand: String? = "codex"
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    private var configURL: URL {
        homeDirectory.appendingPathComponent(".codex/config.toml")
    }

    private var codexDir: URL {
        homeDirectory.appendingPathComponent(".codex")
    }

    func isInstalled() -> Bool {
        ShellHelper.commandExists("codex")
            || FileManager.default.fileExists(atPath: codexDir.path)
    }

    // MARK: - CLI path

    func registerViaCLI(binaryPath: String) throws -> RegistrationOutcome {
        // Remove-then-add is idempotent and dodges "already exists" errors.
        _ = try? ShellHelper.run("codex", ["mcp", "remove", "localmem"])
        try ShellHelper.runOrThrow("codex", ["mcp", "add", "localmem", "--", binaryPath])
        return .registered(via: .cli)
    }

    // MARK: - File path

    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
        var hadPrevious = false
        // Build bottom-up and reassign each level top-down — see preauthorize
        // for the rationale: TOMLKit's `.table` getter may hand back a snapshot,
        // so mutating a sub-table after stashing it back via subscript can be
        // lost.
        let changed = try TOMLConfig.update(at: configURL) { table in
            let mcpServers = table["mcp_servers"]?.table ?? TOMLTable()
            hadPrevious = mcpServers["localmem"] != nil
            let entry = TOMLTable()
            entry["command"] = binaryPath
            mcpServers["localmem"] = entry
            table["mcp_servers"] = mcpServers
        }
        if !changed { return .alreadyRegistered(via: .configFile) }
        return hadPrevious ? .updated(via: .configFile) : .registered(via: .configFile)
    }

    // MARK: - Status

    func isRegistered() -> Bool {
        TOMLConfig.readMcpEntry(at: configURL, serverName: "localmem") != nil
    }

    func registeredBinaryPath() -> String? {
        TOMLConfig.readMcpEntry(at: configURL, serverName: "localmem")?["command"]?.string
    }

    // MARK: - Pre-authorization
    //
    // For each tool, writes `[mcp_servers.localmem.tools.<tool>]` with
    // `approval_mode = "auto"`. Skips `default_tools_approval_mode` so future
    // unlisted tools still prompt.

    func preauthorize(tools: [String]) throws -> PreauthorizationOutcome {
        var alreadyAuthorized = 0
        // Build bottom-up and reassign each level top-down so we don't depend
        // on whether TOMLKit's `.table` getter returns a live reference vs a
        // snapshot — both behaviors flow through this pattern.
        let changed = try TOMLConfig.update(at: configURL) { table in
            let mcpServers = table["mcp_servers"]?.table ?? TOMLTable()
            let localmem = mcpServers["localmem"]?.table ?? TOMLTable()
            let toolsTable = localmem["tools"]?.table ?? TOMLTable()
            for tool in tools {
                let entry = toolsTable[tool]?.table ?? TOMLTable()
                if entry["approval_mode"]?.string == "auto" {
                    alreadyAuthorized += 1
                    continue
                }
                entry["approval_mode"] = "auto"
                toolsTable[tool] = entry
            }
            localmem["tools"] = toolsTable
            mcpServers["localmem"] = localmem
            table["mcp_servers"] = mcpServers
        }
        if !changed { return .alreadyAuthorized(scope: .tools(count: tools.count)) }
        return alreadyAuthorized == 0
            ? .authorized(scope: .tools(count: tools.count))
            : .updated(scope: .tools(count: tools.count))
    }

    func preauthorizationState(tools: [String]) -> PreauthorizationState {
        guard let entry = TOMLConfig.readMcpEntry(at: configURL, serverName: "localmem"),
              let toolsTable = entry["tools"]?.table
        else { return .notAuthorized }
        var missing = 0
        for tool in tools {
            if toolsTable[tool]?.table?["approval_mode"]?.string != "auto" {
                missing += 1
            }
        }
        if missing == 0 { return .authorized }
        if missing == tools.count { return .notAuthorized }
        return .partial(missing: missing)
    }
}
