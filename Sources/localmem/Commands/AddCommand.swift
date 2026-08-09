import ArgumentParser
import Foundation
import LocalmemCore

struct AddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a memory to the local store."
    )

    @Argument(help: "The memory content.")
    var content: String

    @Option(help: "Memory type: fact, preference, decision, project, or note.")
    var type: MemoryType = .note

    @Option(help: "Optional title.")
    var title: String?

    @Option(name: .customLong("tag"), parsing: .singleValue,
            help: "Add a tag. Repeat the flag for multiple tags.")
    var tags: [String] = []

    @Option(help: "Folder to file the memory into — name or UUID. Defaults to Inbox.")
    var folder: String?

    @Flag(help: "Emit JSON of the created memory.")
    var json: Bool = false

    func run() async throws {
        let store = try MemoryStore()
        let memory = try await store.add(
            content: content,
            type: type,
            title: title,
            tags: tags,
            folderID: try await resolveFolderID(store),
            actorKind: .cli,
            actorID: "user"
        )
        if json {
            try OutputFormatter.printJSON([memory])
        } else {
            OutputFormatter.printDetail(memory)
        }
    }

    /// `folder create` existed with no way to put anything in the folder it
    /// made. Accepts a UUID or a name, matched case-insensitively so
    /// `--folder inbox` works.
    private func resolveFolderID(_ store: MemoryStore) async throws -> UUID? {
        guard let folder, !folder.isEmpty else { return nil }
        if let uuid = UUID(uuidString: folder) { return uuid }
        let folders = try await store.listFolders()
        guard let match = folders.first(where: {
            $0.name.compare(folder, options: .caseInsensitive) == .orderedSame
        }) else {
            let names = folders.map(\.name).sorted().joined(separator: ", ")
            throw ValidationError("No folder named \"\(folder)\". Existing folders: \(names)")
        }
        return match.id
    }
}

// Lets argument-parser accept `--type note` etc. directly.
// MemoryType is String-backed, so the conformance is satisfied by default.
extension MemoryType: ExpressibleByArgument {}
