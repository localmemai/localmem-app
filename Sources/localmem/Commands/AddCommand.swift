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

    @Flag(help: "Emit JSON of the created memory.")
    var json: Bool = false

    func run() async throws {
        let store = try MemoryStore()
        let memory = try await store.add(
            content: content,
            type: type,
            title: title,
            tags: tags,
            source: .user
        )
        if json {
            try OutputFormatter.printJSON([memory])
        } else {
            OutputFormatter.printDetail(memory)
        }
    }
}

// Lets argument-parser accept `--type note` etc. directly.
// MemoryType is String-backed, so the conformance is satisfied by default.
extension MemoryType: ExpressibleByArgument {}
