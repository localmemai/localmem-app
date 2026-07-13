import ArgumentParser
import Foundation
import LocalmemCore

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show full content of a memory."
    )

    @Argument(help: "Memory id (full UUID, or unique prefix).")
    var idOrPrefix: String

    @Flag(help: "Emit JSON instead of a detail view.")
    var json: Bool = false

    func run() async throws {
        let store = try MemoryStore()

        try render(try await resolve(idOrPrefix: idOrPrefix, store: store))
    }

    func resolve(idOrPrefix: String, store: MemoryStore) async throws -> Memory {
        // Stage A: try the input as a full UUID.
        if let uuid = UUID(uuidString: idOrPrefix),
           let memory = try await store.get(id: uuid) {
            return memory
        }

        // Stage B: case-insensitive prefix match resolved by the store.
        let candidates = try await store.findIDs(prefix: idOrPrefix)
        guard let id = candidates.first else {
            throw ValidationError("No memory matching '\(idOrPrefix)'.")
        }
        guard candidates.count == 1 else {
            throw ValidationError("Ambiguous prefix '\(idOrPrefix)' matches multiple memories.")
        }
        guard let memory = try await store.get(id: id) else {
            throw ValidationError("No memory matching '\(idOrPrefix)'.")
        }
        return memory
    }

    private func render(_ memory: Memory) throws {
        if json {
            try OutputFormatter.printJSON([memory])
        } else {
            OutputFormatter.printDetail(memory)
        }
    }
}
