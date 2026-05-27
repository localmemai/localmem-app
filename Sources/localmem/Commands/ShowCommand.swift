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

        // Stage A: try the input as a full UUID.
        if let uuid = UUID(uuidString: idOrPrefix),
           let memory = try await store.get(id: uuid) {
            try render(memory)
            return
        }

        // Stage B: case-insensitive prefix match against recent memories.
        let candidates = try await store.recent(limit: 500)
            .filter { $0.id.uuidString.lowercased().hasPrefix(idOrPrefix.lowercased()) }

        guard let memory = candidates.first else {
            throw ValidationError("No memory matching '\(idOrPrefix)'.")
        }
        guard candidates.count == 1 else {
            throw ValidationError("Ambiguous prefix '\(idOrPrefix)' matches \(candidates.count) memories.")
        }
        try render(memory)
    }

    private func render(_ memory: Memory) throws {
        if json {
            try OutputFormatter.printJSON([memory])
        } else {
            OutputFormatter.printDetail(memory)
        }
    }
}
