import Testing
import Foundation
import TOMLKit
@testable import localmem

@Suite("TOMLConfig")
struct TOMLConfigTests {

    // MARK: - Fixtures

    func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - update

    @Test("update creates the file and any missing parent directories on first write")
    func updateCreatesFileAndParents() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("nested/deep/config.toml")
        let changed = try TOMLConfig.update(at: url) { table in
            let servers = TOMLTable()
            let entry = TOMLTable()
            entry["command"] = "/bin/x"
            servers["localmem"] = entry
            table["mcp_servers"] = servers
        }
        #expect(changed)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let raw = try String(contentsOf: url, encoding: .utf8)
        let parsed = try TOMLTable(string: raw)
        #expect(parsed["mcp_servers"]?.table?["localmem"]?.table?["command"]?.string == "/bin/x")
    }

    @Test("update returns false and skips rewrite when round-trip is identical")
    func updateIsIdempotentWhenUnchanged() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.toml")
        _ = try TOMLConfig.update(at: url) { table in
            let servers = TOMLTable()
            let entry = TOMLTable()
            entry["command"] = "/bin/x"
            servers["localmem"] = entry
            table["mcp_servers"] = servers
        }

        let secondChanged = try TOMLConfig.update(at: url) { _ in /* no-op */ }
        #expect(secondChanged == false)
    }

    @Test("update preserves unrelated top-level keys from an existing file")
    func updatePreservesUnrelatedKeys() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.toml")
        try "unrelated = \"keep me\"\n".write(to: url, atomically: true, encoding: .utf8)

        let changed = try TOMLConfig.update(at: url) { table in
            let servers = TOMLTable()
            let entry = TOMLTable()
            entry["command"] = "/our/bin"
            servers["localmem"] = entry
            table["mcp_servers"] = servers
        }
        #expect(changed)

        let parsed = try TOMLTable(string: try String(contentsOf: url, encoding: .utf8))
        #expect(parsed["unrelated"]?.string == "keep me")
        #expect(parsed["mcp_servers"]?.table?["localmem"]?.table?["command"]?.string == "/our/bin")
    }

    // MARK: - readMcpEntry

    @Test("readMcpEntry returns nil when the file is missing")
    func readReturnsNilWhenFileMissing() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(TOMLConfig.readMcpEntry(
            at: root.appendingPathComponent("absent.toml"),
            serverName: "localmem"
        ) == nil)
    }

    @Test("readMcpEntry returns the entry table when present")
    func readReturnsEntryWhenPresent() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.toml")
        _ = try TOMLConfig.update(at: url) { table in
            let servers = TOMLTable()
            let entry = TOMLTable()
            entry["command"] = "/bin/x"
            servers["localmem"] = entry
            table["mcp_servers"] = servers
        }

        let entry = TOMLConfig.readMcpEntry(at: url, serverName: "localmem")
        #expect(entry?["command"]?.string == "/bin/x")
    }

    @Test("readMcpEntry returns nil when the server name is absent")
    func readReturnsNilWhenServerMissing() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.toml")
        _ = try TOMLConfig.update(at: url) { table in
            let servers = TOMLTable()
            let entry = TOMLTable()
            entry["command"] = "/bin/x"
            servers["other"] = entry
            table["mcp_servers"] = servers
        }

        #expect(TOMLConfig.readMcpEntry(at: url, serverName: "localmem") == nil)
    }
}
