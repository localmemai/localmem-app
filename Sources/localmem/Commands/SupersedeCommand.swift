import ArgumentParser
import Foundation
import LocalmemCore

struct SupersedeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supersede",
        abstract: "Mark a memory as superseded by a newer memory."
    )

    @Argument(help: "The older, superseded memory id (full UUID or prefix).")
    var oldIdOrPrefix: String

    @Option(name: .long, help: "The newer, superseding memory id (full UUID or prefix).")
    var `with`: String

    func run() async throws {
        let store = try MemoryStore()
        
        let oldID = try await resolve(idOrPrefix: oldIdOrPrefix, store: store)
        let newID = try await resolve(idOrPrefix: `with`, store: store)
        
        try await store.supersede(supersededID: oldID, supersedingID: newID, actorKind: .cli)
        
        print("Linked memory \(oldID.uuidString.prefix(8))... as superseded by \(newID.uuidString.prefix(8))...")
    }

    func resolve(idOrPrefix: String, store: MemoryStore) async throws -> UUID {
        if let uuid = UUID(uuidString: idOrPrefix) {
            return uuid
        }
        let candidates = try await store.findIDs(prefix: idOrPrefix)
        guard let id = candidates.first else {
            throw ValidationError("No memory matching '\(idOrPrefix)'.")
        }
        guard candidates.count == 1 else {
            throw ValidationError("Ambiguous prefix '\(idOrPrefix)' matches multiple memories.")
        }
        return id
    }
}
