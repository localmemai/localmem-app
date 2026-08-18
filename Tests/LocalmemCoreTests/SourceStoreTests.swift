import Foundation
import Testing
@testable import LocalmemCore

@Suite("SourceStore")
struct SourceStoreTests {
    private func makeStores() throws -> (MemoryStore, SourceStore) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lm-ss-\(UUID().uuidString).sqlite3")
        let db = try LocalmemDatabase(url: url)
        return (MemoryStore(database: db), SourceStore(database: db))
    }

    @Test("A source round-trips through add, get, update, and delete")
    func crudRoundTrip() async throws {
        let (_, store) = try makeStores()
        let source = ImportSource(name: "notes.md", path: "/tmp/notes.md", backend: .apple)
        try await store.add(source)

        // get + list reflect the insert.
        let fetched = try await store.get(id: source.id)
        #expect(fetched?.name == "notes.md")
        #expect(fetched?.backend == .apple)
        #expect(try await store.list().count == 1)

        // update mutates name + backend.
        var edited = source
        edited.name = "renamed.md"
        edited.backend = .agent("claude-code")
        edited.lastRunAt = Date()
        try await store.update(edited)

        let after = try await store.get(id: source.id)
        #expect(after?.name == "renamed.md")
        #expect(after?.backend == .agent("claude-code"))
        #expect(after?.lastRunAt != nil)

        // delete removes it.
        try await store.delete(id: source.id)
        #expect(try await store.get(id: source.id) == nil)
        #expect(try await store.list().isEmpty)
    }

    @Test("allMemoryIDs returns a source's linked memories, and deleting them clears the link")
    func linkedMemories() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let source = ImportSource(name: "doc.md", path: "/tmp/doc.md", backend: .apple)
        try await sourceStore.add(source)

        let memories = [
            Memory(type: .fact, title: "One", content: "1.", tags: [], source: "import"),
            Memory(type: .fact, title: "Two", content: "2.", tags: [], source: "import"),
        ]
        try await memoryStore.importMemories(memories, actorKind: .cli, actorID: "import")
        for m in memories {
            try await sourceStore.link(memoryID: m.id, sourceID: source.id, relPath: "doc.md")
        }

        #expect(Set(try await sourceStore.allMemoryIDs(sourceID: source.id)) == Set(memories.map(\.id)))

        try await sourceStore.deleteMemories(ids: memories.map(\.id), actorKind: .cli, actorID: "user")
        #expect(try await sourceStore.allMemoryIDs(sourceID: source.id).isEmpty)
        #expect(try await memoryStore.count() == 0)
    }

    @Test("replaceMemories swaps a file's memories atomically and links the new set")
    func replaceMemoriesSwapsAndLinks() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let source = ImportSource(name: "doc.md", path: "/tmp/doc.md", backend: .apple)
        try await sourceStore.add(source)

        let old = [Memory(type: .fact, title: "Old", content: "Old fact.", tags: ["a"], source: "import")]
        try await sourceStore.replaceMemories(
            sourceID: source.id, relPath: "doc.md", with: old,
            actorKind: .cli, actorID: "import")
        #expect(Set(try await sourceStore.allMemoryIDs(sourceID: source.id)) == Set(old.map(\.id)))

        let new = [
            Memory(type: .fact, title: "New 1", content: "New fact one.", tags: [], source: "import"),
            Memory(type: .preference, title: "New 2", content: "New fact two.", tags: ["b"], source: "import"),
        ]
        let imported = try await sourceStore.replaceMemories(
            sourceID: source.id, relPath: "doc.md", with: new,
            actorKind: .cli, actorID: "import")

        // Old set gone, new set present and linked; tags rode along.
        #expect(imported == 2)
        #expect(try await memoryStore.get(id: old[0].id) == nil)
        #expect(Set(try await sourceStore.allMemoryIDs(sourceID: source.id)) == Set(new.map(\.id)))
        #expect(try await memoryStore.get(id: new[1].id)?.tags == ["b"])
        #expect(try await memoryStore.count() == 2)
    }

    @Test("replaceMemories with an empty set leaves the file's memories alone")
    func replaceMemoriesEmptySetKeepsExisting() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let source = ImportSource(name: "doc.md", path: "/tmp/doc.md", backend: .apple)
        try await sourceStore.add(source)

        let old = [Memory(type: .fact, title: "Old", content: "Old fact.", tags: [], source: "import")]
        try await sourceStore.replaceMemories(
            sourceID: source.id, relPath: "doc.md", with: old,
            actorKind: .cli, actorID: "import")

        let imported = try await sourceStore.replaceMemories(
            sourceID: source.id, relPath: "doc.md", with: [],
            actorKind: .cli, actorID: "import")
        // Previously this cleared the file's memories, which made any fact-free
        // or failed re-run destructive: an extraction that produced nothing
        // would trade the existing set for it. An empty result is now a no-op,
        // and the user deletes deliberately.
        #expect(imported == 0)
        #expect(try await sourceStore.allMemoryIDs(sourceID: source.id).count == 1)
        #expect(try await memoryStore.count() == 1)
    }

    @Test("get returns nil for an unknown id")
    func getUnknown() async throws {
        let (_, store) = try makeStores()
        #expect(try await store.get(id: UUID()) == nil)
    }

    /// `memoryIDs(sourceID:relPath:)` is the per-file view of the link table —
    /// narrower than `allMemoryIDs`, and what a re-import consults to decide
    /// which memories one file owns.
    @Test("memoryIDs returns one file's memories, scoped by both source and path")
    func memoryIDsAreScopedPerFile() async throws {
        let (memories, sources) = try makeStores()
        let source = ImportSource(name: "vault", path: "/tmp/vault", backend: .apple)
        let other = ImportSource(name: "other", path: "/tmp/other", backend: .apple)
        try await sources.add(source)
        try await sources.add(other)

        let a = try await memories.add(content: "from a.md", type: .note, actorKind: .cli, actorID: "user")
        let b = try await memories.add(content: "also from a.md", type: .note, actorKind: .cli, actorID: "user")
        let c = try await memories.add(content: "from b.md", type: .note, actorKind: .cli, actorID: "user")
        let d = try await memories.add(content: "different source", type: .note, actorKind: .cli, actorID: "user")

        try await sources.link(memoryID: a.id, sourceID: source.id, relPath: "a.md")
        try await sources.link(memoryID: b.id, sourceID: source.id, relPath: "a.md")
        try await sources.link(memoryID: c.id, sourceID: source.id, relPath: "b.md")
        try await sources.link(memoryID: d.id, sourceID: other.id, relPath: "a.md")

        let forA = try await sources.memoryIDs(sourceID: source.id, relPath: "a.md")
        #expect(Set(forA) == Set([a.id, b.id]))

        let forB = try await sources.memoryIDs(sourceID: source.id, relPath: "b.md")
        #expect(forB == [c.id])

        // Same rel path under a different source is a different file.
        #expect(try await sources.memoryIDs(sourceID: other.id, relPath: "a.md") == [d.id])
    }

    @Test("memoryIDs returns nothing for a file with no linked memories")
    func memoryIDsEmptyForUnknownFile() async throws {
        let (_, sources) = try makeStores()
        let source = ImportSource(name: "vault", path: "/tmp/vault", backend: .apple)
        try await sources.add(source)

        #expect(try await sources.memoryIDs(sourceID: source.id, relPath: "never-imported.md").isEmpty)
    }

}

@Suite("SourceStore folders")
struct SourceStoreFolderTests {
    private func makeStores() throws -> (MemoryStore, SourceStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lm-\(UUID().uuidString).sqlite3")
        let db = try LocalmemDatabase(url: url)
        return (MemoryStore(database: db), SourceStore(database: db), url)
    }

    @Test("imported memories are filed under their source's directory, not Inbox")
    func importedMemoriesGetASourceFolder() async throws {
        let (memoryStore, sourceStore, url) = try makeStores()
        defer { try? FileManager.default.removeItem(at: url) }

        // Two files in one directory must collapse into a single folder —
        // `sources` holds one row per file.
        let a = ImportSource(name: "a.pdf", path: "/tmp/Docs/Statements/a.pdf", backend: .apple)
        let b = ImportSource(name: "b.pdf", path: "/tmp/Docs/Statements/b.pdf", backend: .apple)
        try await sourceStore.add(a)
        try await sourceStore.add(b)

        _ = try await sourceStore.replaceMemories(
            sourceID: a.id, relPath: "a.pdf",
            with: [Memory(type: .fact, content: "from a", source: "import")],
            actorKind: .cli, actorID: "import")
        _ = try await sourceStore.replaceMemories(
            sourceID: b.id, relPath: "b.pdf",
            with: [Memory(type: .fact, content: "from b", source: "import")],
            actorKind: .cli, actorID: "import")

        let folders = try await memoryStore.listFolders()
        let sourceFolders = folders.filter { $0.kind == .source }
        #expect(sourceFolders.count == 1)
        let folder = try #require(sourceFolders.first)
        #expect(folder.name == "Statements")
        #expect(folder.isSensitive == false) // an import never restricts access

        let inbox = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let filed = try await memoryStore.memories(inFolder: folder.id)
        #expect(filed.count == 2)
        #expect(try await memoryStore.memories(inFolder: inbox).isEmpty)
    }

    @Test("a run that extracts nothing leaves the previous memories intact")
    func emptyExtractionDoesNotDestroyExistingMemories() async throws {
        let (memoryStore, sourceStore, url) = try makeStores()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = ImportSource(name: "doc.pdf", path: "/tmp/Docs/Reports/doc.pdf", backend: .apple)
        try await sourceStore.add(source)

        _ = try await sourceStore.replaceMemories(
            sourceID: source.id, relPath: "doc.pdf",
            with: [
                Memory(type: .fact, content: "first", source: "import"),
                Memory(type: .fact, content: "second", source: "import"),
            ],
            actorKind: .cli, actorID: "import")
        #expect(try await memoryStore.count() == 2)

        // A failed or fact-free re-run must not trade real memories for nothing.
        let imported = try await sourceStore.replaceMemories(
            sourceID: source.id, relPath: "doc.pdf", with: [],
            actorKind: .cli, actorID: "import")
        #expect(imported == 0)
        #expect(try await memoryStore.count() == 2)

        // A run that *does* produce facts still replaces as before.
        _ = try await sourceStore.replaceMemories(
            sourceID: source.id, relPath: "doc.pdf",
            with: [Memory(type: .fact, content: "third", source: "import")],
            actorKind: .cli, actorID: "import")
        #expect(try await memoryStore.count() == 1)
    }
}
