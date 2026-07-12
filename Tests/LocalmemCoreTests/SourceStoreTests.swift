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

    @Test("replaceMemories with an empty set clears the file's memories")
    func replaceMemoriesEmptySetClears() async throws {
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
        #expect(imported == 0)
        #expect(try await sourceStore.allMemoryIDs(sourceID: source.id).isEmpty)
        #expect(try await memoryStore.count() == 0)
    }

    @Test("get returns nil for an unknown id")
    func getUnknown() async throws {
        let (_, store) = try makeStores()
        #expect(try await store.get(id: UUID()) == nil)
    }
}
