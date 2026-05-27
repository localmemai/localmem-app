import Foundation
import TOMLKit

struct CodexRegistrar: ClientRegistrar {
    let displayName = "Codex"
    let cliCommand: String? = "codex"

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    private var codexDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
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
        let changed = try TOMLConfig.update(at: configURL) { table in
            let mcpServers: TOMLTable
            if let existing = table["mcp_servers"]?.table {
                mcpServers = existing
                hadPrevious = existing["localmem"] != nil
            } else {
                mcpServers = TOMLTable()
                table["mcp_servers"] = mcpServers
            }
            let entry = TOMLTable()
            entry["command"] = binaryPath
            mcpServers["localmem"] = entry
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
}
