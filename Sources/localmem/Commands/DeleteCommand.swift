import ArgumentParser
import Foundation
import LocalmemCore
#if canImport(Darwin)
import Darwin
#endif

struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a memory by id or unique prefix."
    )

    @Argument(help: "Memory id (full UUID, or unique prefix).")
    var idOrPrefix: String

    @Flag(name: .shortAndLong, help: "Skip the confirmation prompt.")
    var force: Bool = false

    func run() async throws {
        let store = try MemoryStore()
        let memory = try await resolve(idOrPrefix: idOrPrefix, store: store)

        // Show exactly what's about to be deleted so the user can verify.
        renderTarget(memory)

        if !force {
            // Non-interactive contexts must use --force explicitly; we refuse
            // to silently delete in a script that didn't ask.
            guard isatty(FileHandle.standardInput.fileDescriptor) != 0 else {
                throw ValidationError("Refusing to delete in a non-interactive shell. Re-run with --force to confirm.")
            }
            print("Confirm? [y/N]: ", terminator: "")
            guard
                let response = readLine()?.trimmingCharacters(in: .whitespaces),
                let first = response.lowercased().first,
                first == "y"
            else {
                print("Cancelled.")
                return
            }
        }

        let existed = try await store.delete(id: memory.id)
        if existed {
            print("Deleted \(memory.id.uuidString).")
        } else {
            // Race: the memory was deleted between resolve and delete.
            // Unlikely in V1 (no concurrent writers from this surface) but cheap to handle.
            print("Memory was already gone — no change.")
        }
    }

    // MARK: - Helpers

    private func resolve(idOrPrefix: String, store: MemoryStore) async throws -> Memory {
        if let uuid = UUID(uuidString: idOrPrefix),
           let memory = try await store.get(id: uuid) {
            return memory
        }
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

    private func renderTarget(_ memory: Memory) {
        print("Delete this memory?")
        print("  id:    \(memory.id.uuidString)")
        print("  type:  \(memory.type.rawValue)")
        if let title = memory.title { print("  title: \(title)") }
        let preview = memory.content
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(80)
        print("  text:  \(preview)\(memory.content.count > 80 ? "..." : "")")
        print("")
    }
}
