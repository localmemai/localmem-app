import ArgumentParser
import Foundation
import LocalmemCore

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Full-text search over stored memories."
    )

    @Argument(help: "Query string.")
    var query: String

    @Option(name: .shortAndLong, help: "Maximum number of results to show.")
    var limit: Int = 20

    @Flag(help: "Emit JSON instead of a table.")
    var json: Bool = false

    func run() async throws {
        let store = try MemoryStore()
        let memories = try await store.search(query: query, limit: limit)
        if json {
            try OutputFormatter.printJSON(memories)
        } else {
            OutputFormatter.printTable(memories)
        }
    }
}
