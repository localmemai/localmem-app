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
            let name = r.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("  \(name) \(Self.statusLine(for: r, canonical: canonical))")
        }

        print("")
        print("Canonical binary: \(canonical)")
    }

    /// One client's status line: install → registration → path health → pre-auth.
    /// Static and registrar-injected so tests can drive it with fakes, matching
    /// the `SetupCommand.processClient` seam.
    static func statusLine(for r: ClientRegistrar, canonical: String) -> String {
        if !r.isInstalled() {
            return "– not installed"
        }
        if !r.isRegistered() {
            return "✗ installed but NOT registered — run `localmem setup`"
        }
        let registrationDetail: String
        if let path = r.registeredBinaryPath() {
            registrationDetail = path == canonical
                ? "✓ registered · path OK"
                : "↺ registered · path STALE — run `localmem setup`"
        } else {
            registrationDetail = "✓ registered · path unknown"
        }
        return "\(registrationDetail) · \(preauthLabel(for: r))"
    }

    static func preauthLabel(for registrar: ClientRegistrar) -> String {
        switch registrar.preauthorizationState(tools: Localmem.preauthorizedToolNames) {
        case .authorized:           return "auto-approved"
        case .partial(let missing): return "auto-approved (partial, \(missing) missing — re-run setup)"
        case .notAuthorized:        return "prompts each call — re-run setup"
        case .unsupported:          return "no pre-auth mechanism"
        }
    }
}
