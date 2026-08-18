import ArgumentParser
import Foundation
import LocalmemCore

struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "Manage connected agents and their visibility access levels.",
        subcommands: [
            List.self,
            SetStatus.self
        ],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List all connected agents and their status.")

        func run() async throws {
            let store = try MemoryStore()
            let agents = try await store.listAgents()
            print("Connected Agents:")
            for a in agents {
                print("  - \(a.id): \(a.status.rawValue)")
            }
        }
    }

    struct SetStatus: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Set access status for an agent.")

        @Argument(help: "Agent ID.")
        var id: String

        @Flag(name: .shortAndLong, help: "Set status to all (can read sensitive folders).")
        var all: Bool = false

        @Flag(name: .shortAndLong, help: "Set status to non-sensitive-only (restricted).")
        var nonSensitiveOnly: Bool = false

        func run() async throws {
            // Resolved before the store is opened: bad flags are a usage error,
            // not a reason to touch the database.
            let status = try resolvedStatus()
            let store = try MemoryStore()
            try await store.setAgentStatus(id: id, status: status)
            print("Set status for agent '\(id)' to '\(status.rawValue)'.")
        }

        /// The two flags are mutually exclusive and one is required; neither
        /// given is a usage error rather than a silent default.
        func resolvedStatus() throws -> Agent.Status {
            if all {
                return .all
            } else if nonSensitiveOnly {
                return .nonSensitiveOnly
            }
            throw ValidationError("Must specify either --all or --non-sensitive-only.")
        }
    }
}
