import ArgumentParser
import Foundation
import LocalmemCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report store stats and MCP client registration health."
    )

    func run() async throws {
        // MARK: Store stats
        let store = try MemoryStore()
        let dbPath = try Paths.databaseURL().path
        let recent = try await store.recent(limit: 1)
        let total = try await store.count()

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: dbPath)[.size] as? Int) ?? 0

        print("Localmem Status")
        print(String(repeating: "=", count: 56))
        print("")
        print("Store")
        print("  Database:    \(dbPath)")
        print("  Memories:    \(total)")
        if let lastWrite = recent.first?.createdAt {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            print("  Last write:  \(fmt.string(from: lastWrite))")
        } else {
            print("  Last write:  (none yet)")
        }
        print("  Disk usage:  \(fileSize / 1024) KB")

        // MARK: Client connectivity
        let canonical = (try? BinaryLocator.mcpServerPath()) ?? "<unresolved>"
        print("")
        print("MCP clients")

        let registrars: [ClientRegistrar] = [
            ClaudeCodeRegistrar(),
            CodexRegistrar(),
            ClaudeDesktopRegistrar(),
            AntigravityRegistrar(),
            CursorRegistrar(),
        ]

        for r in registrars {
            let line: String
            if !r.isInstalled() {
                line = "– not installed"
            } else if !r.isRegistered() {
                line = "✗ installed but NOT registered — run `localmem setup`"
            } else if let path = r.registeredBinaryPath() {
                line = path == canonical
                    ? "✓ registered · path OK"
                    : "↺ registered · path STALE — run `localmem setup`"
            } else {
                line = "✓ registered · path unknown"
            }
            let name = r.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("  \(name) \(line)")
        }

        print("")
        print("Canonical binary: \(canonical)")
    }
}
