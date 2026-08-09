import ArgumentParser
import Foundation
import LocalmemCore

struct FolderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folder",
        abstract: "Manage folders.",
        subcommands: [
            List.self,
            Create.self,
            Delete.self,
            Merge.self
        ]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List all folders.")

        func run() async throws {
            let store = try MemoryStore()
            let folders = try await store.listFolders()
            print("Folders:")
            for f in folders {
                let sensitiveMarker = f.isSensitive ? " [SENSITIVE]" : ""
                let rootInfo = f.projectRoot.map { " (root: \($0))" } ?? ""
                print("  - \(f.name) (\(f.kind.rawValue))\(sensitiveMarker)\(rootInfo)")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new folder.")

        @Argument(help: "Folder name.")
        var name: String

        @Flag(name: .shortAndLong, help: "Mark the folder as sensitive.")
        var sensitive: Bool = false

        func run() async throws {
            let store = try MemoryStore()
            let folder = try await store.createFolder(name: name, kind: .manual, projectRoot: nil, isSensitive: sensitive)
            print("Created folder '\(folder.name)' with ID \(folder.id.uuidString).")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a folder.")

        @Argument(help: "Folder UUID.")
        var id: String

        func run() async throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID format: \(id)")
            }
            let store = try MemoryStore()
            try await store.deleteFolder(id: uuid)
            print("Deleted folder \(id). Memories have been reassigned to Inbox.")
        }
    }

    struct Merge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "merge", abstract: "Merge folders into a new/existing one.")

        @Argument(help: "Comma-separated folder UUIDs.")
        var ids: String

        @Argument(help: "Target folder name.")
        var targetName: String

        func run() async throws {
            let uuids = ids.components(separatedBy: ",").compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !uuids.isEmpty else {
                throw ValidationError("Must specify at least one valid UUID.")
            }
            let store = try MemoryStore()
            let folder = try await store.mergeFolders(ids: uuids, intoName: targetName)
            print("Merged folders into '\(folder.name)' (ID: \(folder.id.uuidString)).")
        }
    }
}
