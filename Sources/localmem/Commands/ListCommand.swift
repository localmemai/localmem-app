import ArgumentParser
import Foundation
import LocalmemCore

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
        let database = try LocalmemDatabase()
        let store = MemoryStore(database: database)
        let activityStore = ActivityStore(database: database)

        let memories = try await store.recent(limit: limit)
        do {
            try await activityStore.add(Activity(
                actorKind: .cli,
                operation: "memory_recent",
                resultCount: memories.count
            ))
        } catch {
            Log.error(.cli, "Failed to write activity row", [
                "operation": "memory_recent",
                "error": String(describing: error),
            ])
        }

        if json {
            try OutputFormatter.printJSON(memories)
        } else {
            OutputFormatter.printTable(memories)
        }
    }
}
