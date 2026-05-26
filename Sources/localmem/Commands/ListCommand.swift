import ArgumentParser
import Foundation
import LocalMemCore

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List most recent memories."
    )

    @Option(name: .shortAndLong, help: "Maximum number of memories to show.")
    var limit: Int = 20

    @Flag(help: "Emit JSON instead of a table.")
    var json: Bool = false

    func run() async throws {
        let store = try MemoryStore()
        let memories = try await store.recent(limit: limit)
        if json {
            try OutputFormatter.printJSON(memories)
        } else {
            OutputFormatter.printTable(memories)
        }
    }
}
