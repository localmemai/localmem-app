import Testing
import Foundation
@testable import localmem

@Suite("JSONConfig")
struct JSONConfigTests {

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

        let url = root
            .appendingPathComponent("nested/deep/config.json")
        let changed = try JSONConfig.update(at: url) { _ in
            ["mcpServers": ["localmem": ["command": "/bin/x"]]]
        }
        #expect(changed)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let root1 = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = root1?["mcpServers"] as? [String: Any]
        #expect((servers?["localmem"] as? [String: Any])?["command"] as? String == "/bin/x")
    }

    @Test("update returns false and skips rewrite when structurally identical")
    func updateIsIdempotentWhenUnchanged() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.json")
        _ = try JSONConfig.update(at: url) { _ in
            ["mcpServers": ["localmem": ["command": "/bin/x"]]]
        }

        // Same input on the second call must report no change.
        let secondChanged = try JSONConfig.update(at: url) { current in current }
        #expect(secondChanged == false)
    }

    @Test("update preserves unrelated top-level keys from an existing file")
    func updatePreservesUnrelatedKeys() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.json")
        let seed: [String: Any] = [
            "unrelated": "keep me",
            "mcpServers": ["other": ["command": "/other/bin"]],
        ]
        try JSONSerialization
            .data(withJSONObject: seed, options: [.prettyPrinted, .sortedKeys])
            .write(to: url)

        let changed = try JSONConfig.update(at: url) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            servers["localmem"] = ["command": "/our/bin"]
            next["mcpServers"] = servers
            return next
        }
        #expect(changed)

        let data = try Data(contentsOf: url)
        let root1 = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(root1?["unrelated"] as? String == "keep me")
        let servers = root1?["mcpServers"] as? [String: Any]
        #expect((servers?["other"] as? [String: Any])?["command"] as? String == "/other/bin")
        #expect((servers?["localmem"] as? [String: Any])?["command"] as? String == "/our/bin")
    }

    // MARK: - readMcpEntry

    @Test("readMcpEntry returns nil when the file is missing")
    func readReturnsNilWhenFileMissing() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("absent.json")
        #expect(JSONConfig.readMcpEntry(at: url, serverName: "localmem") == nil)
    }

    @Test("readMcpEntry returns the entry dict when present")
    func readReturnsEntryWhenPresent() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.json")
        _ = try JSONConfig.update(at: url) { _ in
            ["mcpServers": ["localmem": ["command": "/bin/x"]]]
        }

        let entry = JSONConfig.readMcpEntry(at: url, serverName: "localmem")
        #expect(entry?["command"] as? String == "/bin/x")
    }

    @Test("readMcpEntry returns nil when the server name is absent")
    func readReturnsNilWhenServerMissing() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.json")
        _ = try JSONConfig.update(at: url) { _ in
            ["mcpServers": ["other": ["command": "/bin/x"]]]
        }

        #expect(JSONConfig.readMcpEntry(at: url, serverName: "localmem") == nil)
    }

    @Test("readMcpEntry honors a custom mcpServersKey")
    func readHonorsCustomServersKey() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("config.json")
        _ = try JSONConfig.update(at: url) { _ in
            ["custom_key": ["localmem": ["command": "/bin/x"]]]
        }

        let entry = JSONConfig.readMcpEntry(at: url, mcpServersKey: "custom_key", serverName: "localmem")
        #expect(entry?["command"] as? String == "/bin/x")
    }
}
