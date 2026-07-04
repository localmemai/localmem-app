import Foundation
import Testing
import TOMLKit
@testable import localmem

/// File-based registration is the fallback path every registrar must implement,
/// and the read-back accessors (`isRegistered`, `registeredBinaryPath`) are what
/// `localmem status` reports on. The matrix below covers, per registrar:
///
/// * greenfield → `.registered(via: .configFile)`, file written, read-back OK
/// * second call with same binary path → `.alreadyRegistered`
/// * re-register with a different binary path → `.updated`, read-back reflects it
/// * preserves an unrelated `mcpServers.other` entry
@Suite("File-based registration per registrar")
struct RegistrationTests {

    static let binaryA = "/opt/localmem/A/localmem-mcp"
    static let binaryB = "/opt/localmem/B/localmem-mcp"

    static func makeHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Claude Code

    @Suite("Claude Code")
    struct ClaudeCode {
        private func configURL(home: URL) -> URL {
            home.appendingPathComponent(".claude.json")
        }

        @Test("greenfield writes the mcpServers.localmem entry")
        func greenfield() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            let outcome = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .registered(.configFile) = outcome else {
                Issue.record("expected .registered(.configFile), got \(outcome)")
                return
            }
            #expect(r.isRegistered())
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryA)
        }

        @Test("second call with the same binary path is .alreadyRegistered")
        func idempotent() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            let second = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .alreadyRegistered(.configFile) = second else {
                Issue.record("expected .alreadyRegistered, got \(second)")
                return
            }
        }

        @Test("re-registering with a different binary path returns .updated and rewrites command")
        func updatedOnBinaryChange() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            let outcome = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryB)
            guard case .updated(.configFile) = outcome else {
                Issue.record("expected .updated, got \(outcome)")
                return
            }
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryB)
        }

        @Test("preserves an unrelated mcpServers.other entry")
        func preservesUnrelatedServers() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = configURL(home: home)
            try JSONConfig.update(at: url) { _ in
                ["mcpServers": ["other": ["command": "/other/bin"]]]
            }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)

            let other = JSONConfig.readMcpEntry(at: url, serverName: "other")
            #expect((other?["command"] as? String) == "/other/bin")
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryA)
        }

        @Test("isRegistered is false and registeredBinaryPath is nil on a clean home")
        func unregisteredHome() {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeCodeRegistrar(homeDirectory: home)
            #expect(r.isRegistered() == false)
            #expect(r.registeredBinaryPath() == nil)
        }
    }

    // MARK: - Claude Desktop

    @Suite("Claude Desktop")
    struct ClaudeDesktop {
        private func configURL(home: URL) -> URL {
            home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        }

        @Test("greenfield writes the mcpServers.localmem entry")
        func greenfield() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            let outcome = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .registered(.configFile) = outcome else {
                Issue.record("expected .registered(.configFile), got \(outcome)")
                return
            }
            #expect(r.isRegistered())
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryA)
        }

        @Test("idempotent on second call with the same binary path")
        func idempotent() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            let second = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .alreadyRegistered(.configFile) = second else {
                Issue.record("expected .alreadyRegistered, got \(second)")
                return
            }
        }

        @Test("re-registering with a different binary path returns .updated")
        func updatedOnBinaryChange() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            let outcome = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryB)
            guard case .updated(.configFile) = outcome else {
                Issue.record("expected .updated, got \(outcome)")
                return
            }
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryB)
        }

        @Test("unregistered home reads back as nil")
        func unregisteredHome() {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = ClaudeDesktopRegistrar(homeDirectory: home)
            #expect(r.isRegistered() == false)
            #expect(r.registeredBinaryPath() == nil)
        }
    }

    // MARK: - Cursor

    @Suite("Cursor")
    struct Cursor {
        @Test("greenfield writes the mcpServers.localmem entry")
        func greenfield() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CursorRegistrar(homeDirectory: home)
            let outcome = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .registered(.configFile) = outcome else {
                Issue.record("expected .registered(.configFile), got \(outcome)")
                return
            }
            #expect(r.isRegistered())
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryA)
        }

        @Test("idempotent on second call with the same binary path")
        func idempotent() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CursorRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            let second = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .alreadyRegistered(.configFile) = second else {
                Issue.record("expected .alreadyRegistered, got \(second)")
                return
            }
        }

        @Test("unregistered home reads back as nil")
        func unregisteredHome() {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CursorRegistrar(homeDirectory: home)
            #expect(r.isRegistered() == false)
            #expect(r.registeredBinaryPath() == nil)
        }
    }

    // MARK: - Codex (TOML)

    @Suite("Codex")
    struct Codex {
        private func configURL(home: URL) -> URL {
            home.appendingPathComponent(".codex/config.toml")
        }

        @Test("greenfield writes [mcp_servers.localmem] with command")
        func greenfield() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CodexRegistrar(homeDirectory: home)
            let outcome = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .registered(.configFile) = outcome else {
                Issue.record("expected .registered(.configFile), got \(outcome)")
                return
            }
            #expect(r.isRegistered())
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryA)
        }

        @Test("idempotent on second call with the same binary path")
        func idempotent() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CodexRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            let second = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .alreadyRegistered(.configFile) = second else {
                Issue.record("expected .alreadyRegistered, got \(second)")
                return
            }
        }

        @Test("re-registering with a different binary path returns .updated and rewrites command")
        func updatedOnBinaryChange() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CodexRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            let outcome = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryB)
            guard case .updated(.configFile) = outcome else {
                Issue.record("expected .updated, got \(outcome)")
                return
            }
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryB)
        }

        @Test("preserves an unrelated [mcp_servers.other] entry")
        func preservesUnrelatedServers() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let url = configURL(home: home)
            try TOMLConfig.update(at: url) { table in
                let servers = TOMLTable()
                let other = TOMLTable()
                other["command"] = "/other/bin"
                servers["other"] = other
                table["mcp_servers"] = servers
            }

            let r = CodexRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)

            let other = TOMLConfig.readMcpEntry(at: url, serverName: "other")
            #expect(other?["command"]?.string == "/other/bin")
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryA)
        }

        @Test("unregistered home reads back as nil")
        func unregisteredHome() {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = CodexRegistrar(homeDirectory: home)
            #expect(r.isRegistered() == false)
            #expect(r.registeredBinaryPath() == nil)
        }
    }

    // MARK: - Antigravity

    @Suite("Antigravity")
    struct Antigravity {
        @Test("greenfield writes mcpServers.localmem with command/type/args")
        func greenfield() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = AntigravityRegistrar(homeDirectory: home)
            let outcome = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .registered(.configFile) = outcome else {
                Issue.record("expected .registered(.configFile), got \(outcome)")
                return
            }
            #expect(r.isRegistered())
            #expect(r.registeredBinaryPath() == RegistrationTests.binaryA)
        }

        @Test("idempotent on second call with the same binary path")
        func idempotent() throws {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = AntigravityRegistrar(homeDirectory: home)
            _ = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            let second = try r.registerViaConfigFile(binaryPath: RegistrationTests.binaryA)
            guard case .alreadyRegistered(.configFile) = second else {
                Issue.record("expected .alreadyRegistered, got \(second)")
                return
            }
        }

        @Test("unregistered home reads back as nil")
        func unregisteredHome() {
            let home = RegistrationTests.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let r = AntigravityRegistrar(homeDirectory: home)
            #expect(r.isRegistered() == false)
            #expect(r.registeredBinaryPath() == nil)
        }
    }
}
