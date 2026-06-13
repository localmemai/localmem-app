import ArgumentParser
import Foundation
import LocalmemCore

/// Replace any subset of a memory's mutable fields. Mirrors the MCP
/// `memory_update` tool: omitted flags keep the existing value; an empty
/// `--clear-tags` flag wipes the tag list.
///
/// No confirmation prompt — typing the command IS the confirmation. Matches
/// `localmem add`'s ergonomic. Use `localmem show` first if you want to
/// preview the row before editing.
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an existing memory by id or unique prefix."
    )

    @Argument(help: "Memory id (full UUID, or unique prefix).")
    var idOrPrefix: String

    @Option(help: "New content. Omit to keep the existing content.")
    var content: String?

    @Option(help: "New type: fact, preference, decision, project, or note.")
    var type: MemoryType?

    @Option(help: "New title. Pass empty string to clear; omit to keep current.")
    var title: String?

    @Option(name: .customLong("tag"), parsing: .singleValue,
            help: "Replace the tag list. Repeat the flag for multiple tags. Omit to keep existing tags.")
    var tags: [String] = []

    @Flag(help: "Clear all tags (overrides --tag).")
    var clearTags: Bool = false

    @Flag(help: "Emit JSON of the updated memory.")
    var json: Bool = false

    func run() async throws {
        let store = try MemoryStore()
        let existing = try await resolve(idOrPrefix: idOrPrefix, store: store)

        // Merge each field. Anything the caller didn't specify falls back to
        // the existing value so update is true patch semantics.
        let newContent = content ?? existing.content

        let newType = type ?? existing.type

        // `--title ""` clears the title; `--title` omitted keeps current; non-empty replaces.
        let newTitle: String?
        if let raw = title {
            newTitle = raw.isEmpty ? nil : raw
        } else {
            newTitle = existing.title
        }

        let newTags: [String]
        if clearTags {
            newTags = []
        } else if !tags.isEmpty {
            newTags = tags
        } else {
            newTags = existing.tags
        }

        let updated = try await store.update(
            id: existing.id,
            content: newContent,
            type: newType,
            title: newTitle,
            tags: newTags,
            actorKind: .cli,
            actorID: "user"
        )

        if json {
            try OutputFormatter.printJSON([updated])
        } else {
            OutputFormatter.printDetail(updated)
        }
    }

    /// Resolve a full UUID or unique prefix to a Memory. Same logic as
    /// `ShowCommand.resolve` — kept inline to avoid a sub-package helper.
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
}
