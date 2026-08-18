import Foundation
import Testing
@testable import LocalmemCore

@Suite("Paths")
struct PathsTests {
    @Test("applicationSupportDirectory returns a created Localmem subdirectory")
    func appSupportDirectoryIsCreatedLocalmem() throws {
        let url = try Paths.applicationSupportDirectory()
        #expect(url.lastPathComponent == "Localmem")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("databaseURL is the app-support dir plus localmem.sqlite3")
    func databaseURLIsSiblingOfAppSupport() throws {
        let dir = try Paths.applicationSupportDirectory()
        let db = try Paths.databaseURL()
        #expect(db.deletingLastPathComponent().path == dir.path)
        #expect(db.lastPathComponent == "localmem.sqlite3")
    }

    /// The override exists so the demo vault used for marketing screenshots is
    /// never the developer's real one. If it silently stopped taking effect,
    /// `scripts/seed-demo-vault.sh` would seed — and screenshots would
    /// publish — real memories.
    @Test("LOCALMEM_VAULT_DIR redirects the vault and creates the directory")
    func overrideRedirectsVault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let env = [Paths.vaultDirectoryOverrideKey: dir.path]
        let resolved = try Paths.applicationSupportDirectory(environment: env)

        #expect(resolved.standardizedFileURL.path == dir.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        // Not the real vault — the whole point of the override.
        #expect(resolved.lastPathComponent != "Localmem")
    }

    @Test("the override carries through to databaseURL")
    func overrideAppliesToDatabaseURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Paths.databaseURL(environment: [Paths.vaultDirectoryOverrideKey: dir.path])
        #expect(db.deletingLastPathComponent().standardizedFileURL.path
            == dir.standardizedFileURL.path)
        #expect(db.lastPathComponent == "localmem.sqlite3")
    }

    @Test("a tilde in the override is expanded rather than taken literally")
    func overrideExpandsTilde() throws {
        let name = "localmem-tilde-\(UUID().uuidString)"
        let expanded = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: expanded) }

        let resolved = try Paths.applicationSupportDirectory(
            environment: [Paths.vaultDirectoryOverrideKey: "~/\(name)"])

        #expect(!resolved.path.contains("~"))
        #expect(resolved.standardizedFileURL.path == expanded.standardizedFileURL.path)
    }

    @Test("an empty override is ignored, falling back to the real vault")
    func emptyOverrideIsIgnored() throws {
        let resolved = try Paths.applicationSupportDirectory(
            environment: [Paths.vaultDirectoryOverrideKey: ""])
        #expect(resolved.lastPathComponent == "Localmem")
    }
}
