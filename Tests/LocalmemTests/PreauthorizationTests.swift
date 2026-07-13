import Foundation
import Testing
import TOMLKit
@testable import localmem

/// One suite per registrar. Each covers the six cases in the design's §6:
/// greenfield, idempotent, preserves unrelated entries, union-merges existing
/// tool lists, subset-already-present → `.updated`, and the state read-back.
@Suite("Pre-authorization per registrar")
struct PreauthorizationTests {

    static let tools = ["memory_recent", "memory_search", "memory_store"]

    static func makeHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Claude Desktop

    @Suite("Claude Desktop")
    struct ClaudeDesktop {
        let tools = PreauthorizationTests.tools

        private func configURL(home: URL) -> URL {
            home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        }

        @Test("greenfield writes autoapprove with the requested tools")
        func greenfield() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            let outcome = try r.preauthorize(tools: tools)
            guard case .authorized(.tools(let count)) = outcome else {
                Issue.record("expected .authorized(.tools), got \(outcome)")
                return
            }
            #expect(count == 3)

            let entry = JSONConfig.readMcpEntry(at: configURL(home: home), serverName: "localmem")
            #expect(Set((entry?["autoapprove"] as? [String]) ?? []) == Set(tools))
        }

        @Test("second call is idempotent — alreadyAuthorized")
        func idempotent() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)
            let second = try r.preauthorize(tools: tools)
            guard case .alreadyAuthorized = second else {
                Issue.record("expected .alreadyAuthorized, got \(second)")
                return
            }
        }

        @Test("preserves an unrelated mcpServers.other entry")
        func preservesUnrelatedServers() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = configURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["mcpServers": [
                    "localmem": ["command": "/bin/x"],
                    "other": ["command": "/other/bin", "autoapprove": ["other_tool"]],
                ]]
            }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            let other = JSONConfig.readMcpEntry(at: url, serverName: "other")
            #expect((other?["autoapprove"] as? [String]) == ["other_tool"])
            #expect((other?["command"] as? String) == "/other/bin")
        }

        @Test("union-merges with user-added autoapprove entries")
        func unionMerge() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = configURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["mcpServers": ["localmem": [
                    "command": "/bin/x",
                    "autoapprove": ["custom_user_tool"],
                ]]]
            }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            let entry = JSONConfig.readMcpEntry(at: url, serverName: "localmem")
            let approved = Set((entry?["autoapprove"] as? [String]) ?? [])
            #expect(approved == Set(tools + ["custom_user_tool"]))
        }

        @Test("subset-already-present returns .updated")
        func subsetAlreadyPresent() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = configURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["mcpServers": ["localmem": [
                    "command": "/bin/x",
                    "autoapprove": ["memory_recent"],
                ]]]
            }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            let outcome = try r.preauthorize(tools: tools)
            guard case .updated = outcome else {
                Issue.record("expected .updated, got \(outcome)")
                return
            }
        }

        @Test("preauthorizationState reflects on-disk state")
        func stateReadback() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            // Nothing on disk → notAuthorized.
            if case .notAuthorized = r.preauthorizationState(tools: tools) {} else {
                Issue.record("expected .notAuthorized on empty home")
            }
            // After pre-auth → authorized.
            _ = try r.preauthorize(tools: tools)
            if case .authorized = r.preauthorizationState(tools: tools) {} else {
                Issue.record("expected .authorized after preauthorize")
            }
        }
    }

    // MARK: - Claude Code

    @Suite("Claude Code")
    struct ClaudeCode {
        let tools = PreauthorizationTests.tools

        private func settingsURL(home: URL) -> URL {
            home.appendingPathComponent(".claude/settings.json")
        }

        @Test("greenfield writes permissions.allow with mcp__localmem__ entries")
        func greenfield() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            let outcome = try r.preauthorize(tools: tools)
            if case .authorized = outcome {} else {
                Issue.record("expected .authorized, got \(outcome)")
            }

            let data = try Data(contentsOf: settingsURL(home: home))
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let allow = (root?["permissions"] as? [String: Any])?["allow"] as? [String]
            #expect(Set(allow ?? []) == Set(tools.map { "mcp__localmem__\($0)" }))
        }

        @Test("preserves unrelated permissions.allow entries")
        func preservesUnrelatedAllow() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = settingsURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["permissions": ["allow": ["Bash(npm install)", "WebFetch"]]]
            }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            let data = try Data(contentsOf: url)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let allow = Set(((root?["permissions"] as? [String: Any])?["allow"] as? [String]) ?? [])
            #expect(allow.contains("Bash(npm install)"))
            #expect(allow.contains("WebFetch"))
            #expect(allow.contains("mcp__localmem__memory_store"))
        }

        @Test("idempotent on second pass")
        func idempotent() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)
            let second = try r.preauthorize(tools: tools)
            if case .alreadyAuthorized = second {} else {
                Issue.record("expected .alreadyAuthorized, got \(second)")
            }
        }

        @Test("subset-already-present returns .updated")
        func subsetAlreadyPresent() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = settingsURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["permissions": ["allow": ["mcp__localmem__memory_recent"]]]
            }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            let outcome = try r.preauthorize(tools: tools)
            if case .updated = outcome {} else {
                Issue.record("expected .updated, got \(outcome)")
            }
        }
    }

    // MARK: - Cursor

    @Suite("Cursor")
    struct Cursor {
        let tools = PreauthorizationTests.tools

        private func permissionsURL(home: URL) -> URL {
            home.appendingPathComponent(".cursor/permissions.json")
        }

        @Test("greenfield writes mcpAllowlist with localmem: entries")
        func greenfield() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CursorRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            let data = try Data(contentsOf: permissionsURL(home: home))
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let allow = root?["mcpAllowlist"] as? [String]
            #expect(Set(allow ?? []) == Set(tools.map { "localmem:\($0)" }))
        }

        @Test("union-merges with existing mcpAllowlist entries")
        func unionMerge() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = permissionsURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["mcpAllowlist": ["other-server:foo", "other-server:bar"]]
            }

            let r = CursorRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            let data = try Data(contentsOf: url)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let allow = Set((root?["mcpAllowlist"] as? [String]) ?? [])
            #expect(allow.contains("other-server:foo"))
            #expect(allow.contains("other-server:bar"))
            #expect(allow.contains("localmem:memory_store"))
        }

        @Test("idempotent on second pass")
        func idempotent() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CursorRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)
            let second = try r.preauthorize(tools: tools)
            if case .alreadyAuthorized = second {} else {
                Issue.record("expected .alreadyAuthorized, got \(second)")
            }
        }
    }

    // MARK: - Codex

    @Suite("Codex")
    struct Codex {
        let tools = PreauthorizationTests.tools

        private func configURL(home: URL) -> URL {
            home.appendingPathComponent(".codex/config.toml")
        }

        @Test("greenfield writes per-tool approval_mode = auto")
        func greenfield() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CodexRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            let raw = try String(contentsOf: configURL(home: home), encoding: .utf8)
            let table = try TOMLTable(string: raw)
            let toolsTable = table["mcp_servers"]?.table?["localmem"]?.table?["tools"]?.table
            for tool in tools {
                #expect(toolsTable?[tool]?.table?["approval_mode"]?.string == "auto")
            }
        }

        @Test("does NOT set default_tools_approval_mode (future tools stay gated)")
        func skipsDefaultApprovalMode() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CodexRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            let raw = try String(contentsOf: configURL(home: home), encoding: .utf8)
            let table = try TOMLTable(string: raw)
            let localmem = table["mcp_servers"]?.table?["localmem"]?.table
            #expect(localmem?["default_tools_approval_mode"] == nil)
        }

        @Test("preserves the existing command line in [mcp_servers.localmem]")
        func preservesCommand() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = configURL(home: home)
            try TOMLConfig.update(at: url) { table in
                let servers = TOMLTable()
                let entry = TOMLTable()
                entry["command"] = "/bin/seeded-localmem-mcp"
                servers["localmem"] = entry
                table["mcp_servers"] = servers
            }

            let r = CodexRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            let raw = try String(contentsOf: url, encoding: .utf8)
            let table = try TOMLTable(string: raw)
            let entry = table["mcp_servers"]?.table?["localmem"]?.table
            #expect(entry?["command"]?.string == "/bin/seeded-localmem-mcp")
        }

        @Test("idempotent on second pass")
        func idempotent() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CodexRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)
            let second = try r.preauthorize(tools: tools)
            if case .alreadyAuthorized = second {} else {
                Issue.record("expected .alreadyAuthorized, got \(second)")
            }
        }
    }

    // MARK: - Antigravity

    @Suite("Antigravity")
    struct Antigravity {
        let tools = PreauthorizationTests.tools

        private func configURL(home: URL) -> URL {
            home.appendingPathComponent(".gemini/config/mcp_config.json")
        }

        // Server-wide trust would auto-approve memory_update (deliberately
        // excluded from pre-auth), so the registrar must never write it.

        @Test("preauthorize skips instead of writing server-wide trust")
        func skipsInsteadOfTrusting() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = AntigravityRegistrar(homeDirectory: home)
            let outcome = try r.preauthorize(tools: tools)
            guard case .skipped(let reason) = outcome else {
                Issue.record("expected .skipped, got \(outcome)")
                return
            }
            #expect(reason.contains("memory_update"))
            // Nothing was written — no config file appears.
            #expect(!FileManager.default.fileExists(atPath: configURL(home: home).path))
        }

        @Test("preauthorize leaves an existing config untouched")
        func leavesConfigUntouched() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = configURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["mcpServers": ["localmem": [
                    "command": "/bin/x",
                    "includeTools": ["memory_search"],
                ]]]
            }
            let before = try Data(contentsOf: url)

            let r = AntigravityRegistrar(homeDirectory: home)
            _ = try r.preauthorize(tools: tools)

            #expect(try Data(contentsOf: url) == before)
            let entry = JSONConfig.readMcpEntry(at: url, serverName: "localmem")
            #expect(entry?["trust"] == nil)
        }

        @Test("state still reports a manually user-set trust flag")
        func reportsManualTrust() throws {
            let home = PreauthorizationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = configURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["mcpServers": ["localmem": ["command": "/bin/x", "trust": true]]]
            }

            let r = AntigravityRegistrar(homeDirectory: home)
            guard case .authorized = r.preauthorizationState(tools: tools) else {
                Issue.record("expected .authorized for user-set trust")
                return
            }
        }
    }
}
