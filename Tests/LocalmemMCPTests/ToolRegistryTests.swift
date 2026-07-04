import Testing
import Foundation
import MCP
@testable import LocalmemCore
@testable import localmem_mcp

@Suite("ToolRegistry")
struct ToolRegistryTests {

    // MARK: - Fixtures

    /// Stand up a registry backed by a fresh on-disk store. Caller cleans up.
    func makeRegistry() throws -> (ToolRegistry, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        let database = try LocalmemDatabase(url: tmp)
        let store = MemoryStore(database: database)
        let activityStore = ActivityStore(database: database)
        let identity = MCPClientIdentity(fallback: "test-client")
        return (ToolRegistry(store: store, activityStore: activityStore, identity: identity), tmp)
    }

    // MARK: - Descriptors

    @Test("toolDescriptors lists exactly the four MCP tools")
    func descriptorsCoverAllTools() throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let names = Set(registry.toolDescriptors.map(\.name))
        #expect(names == ["memory_store", "memory_search", "memory_recent", "memory_update"])
    }

    // MARK: - Dispatch (call)

    @Test("call routes memory_store to handleStore and returns the new id")
    func callRoutesStore() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await registry.call(
            name: "memory_store",
            arguments: ["content": .string("hello")]
        )
        let text = result.content.firstText
        #expect(text.contains("\"id\""))
        #expect(text.contains("-"), "id payload should look like a UUID")
    }

    @Test("call routes memory_search and returns matching memories as JSON")
    func callRoutesSearch() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await registry.call(
            name: "memory_store",
            arguments: ["content": .string("uniquely searchable phrase")]
        )

        let result = try await registry.call(
            name: "memory_search",
            arguments: ["query": .string("searchable")]
        )
        let text = result.content.firstText
        #expect(text.contains("uniquely searchable phrase"))
    }

    @Test("calls record activity rows")
    func callsRecordActivityRows() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let database = try LocalmemDatabase(url: tmp)
        let store = MemoryStore(database: database)
        let activityStore = ActivityStore(database: database)
        let identity = MCPClientIdentity(fallback: "test-client")
        let registry = ToolRegistry(store: store, activityStore: activityStore, identity: identity)

        _ = try await registry.call(
            name: "memory_store",
            arguments: ["content": .string("activity searchable phrase")]
        )
        _ = try await registry.call(
            name: "memory_search",
            arguments: ["query": .string("activity")]
        )

        let rows = try await activityStore.recent(limit: 10)
        #expect(rows.map(\.operation).contains("memory_store"))
        #expect(rows.map(\.operation).contains("memory_search"))
        #expect(rows.allSatisfy { $0.actorID == "test-client" })
    }

    @Test("call routes memory_recent and returns newest-first JSON")
    func callRoutesRecent() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await registry.call(name: "memory_store", arguments: ["content": .string("first")])
        _ = try await registry.call(name: "memory_store", arguments: ["content": .string("second")])

        let result = try await registry.call(name: "memory_recent", arguments: nil)
        let text = result.content.firstText
        let firstIdx = text.range(of: "first")?.lowerBound
        let secondIdx = text.range(of: "second")?.lowerBound
        #expect(firstIdx != nil && secondIdx != nil)
        #expect(secondIdx! < firstIdx!, "newest entry must appear first in JSON")
    }

    @Test("Unknown tool name dispatches to methodNotFound")
    func callRejectsUnknownTool() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: MCPError.self) {
            _ = try await registry.call(name: "memory_purge", arguments: nil)
        }
    }

    // MARK: - handleStore arg validation

    @Test("memory_store rejects missing content")
    func storeRejectsMissingContent() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: MCPError.self) {
            _ = try await registry.call(name: "memory_store", arguments: nil)
        }
    }

    @Test("memory_store rejects empty content")
    func storeRejectsEmptyContent() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: MCPError.self) {
            _ = try await registry.call(
                name: "memory_store",
                arguments: ["content": .string("")]
            )
        }
    }

    @Test("memory_store rejects an unknown type value")
    func storeRejectsUnknownType() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: MCPError.self) {
            _ = try await registry.call(
                name: "memory_store",
                arguments: [
                    "content": .string("body"),
                    "type": .string("not_a_type"),
                ]
            )
        }
    }

    @Test("memory_store accepts a known type and applies tags")
    func storeAppliesTypeAndTags() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await registry.call(
            name: "memory_store",
            arguments: [
                "content": .string("preferred order"),
                "type": .string("preference"),
                "title": .string("Coffee"),
                "tags": .array([.string("coffee"), .string("preferences")]),
            ]
        )

        let result = try await registry.call(name: "memory_recent", arguments: nil)
        let text = result.content.firstText
        #expect(text.contains("\"preference\""))
        #expect(text.contains("Coffee"))
        #expect(text.contains("coffee"))
    }

    // MARK: - handleSearch arg validation

    @Test("memory_search rejects a missing query")
    func searchRejectsMissingQuery() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: MCPError.self) {
            _ = try await registry.call(name: "memory_search", arguments: nil)
        }
    }

    @Test("memory_search returns an empty JSON array when nothing matches")
    func searchReturnsEmptyArrayOnMiss() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await registry.call(
            name: "memory_search",
            arguments: ["query": .string("nothing-here")]
        )
        let text = result.content.firstText
        #expect(text == "[]")
    }

    // MARK: - handleUpdate

    /// Helper: create a memory and pull the new id out of the result payload.
    private func storeAndExtractID(
        _ registry: ToolRegistry,
        content: String,
        title: String? = nil,
        type: String? = nil,
        tags: [String] = []
    ) async throws -> UUID {
        var args: [String: Value] = ["content": .string(content)]
        if let title { args["title"] = .string(title) }
        if let type { args["type"] = .string(type) }
        if !tags.isEmpty { args["tags"] = .array(tags.map { .string($0) }) }
        let result = try await registry.call(name: "memory_store", arguments: args)
        // Payload is `{"id":"<uuid>"}` — slice the uuid out by quotes.
        let text = result.content.firstText
        let parts = text.split(separator: "\"")
        guard let uuid = parts.dropFirst(3).first.flatMap({ UUID(uuidString: String($0)) }) else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "couldn't parse id from \(text)"])
        }
        return uuid
    }

    @Test("memory_update rejects missing id")
    func updateRejectsMissingID() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: MCPError.self) {
            _ = try await registry.call(name: "memory_update", arguments: nil)
        }
    }

    @Test("memory_update rejects an unknown id")
    func updateRejectsUnknownID() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: MCPError.self) {
            _ = try await registry.call(
                name: "memory_update",
                arguments: ["id": .string(UUID().uuidString)]
            )
        }
    }

    @Test("memory_update merges: omitted fields keep their current value")
    func updatePreservesOmittedFields() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let id = try await storeAndExtractID(
            registry,
            content: "Original content.",
            title: "Coffee preference",
            type: "preference",
            tags: ["coffee", "preference"]
        )

        // Only update content — title, type, tags should be preserved.
        _ = try await registry.call(
            name: "memory_update",
            arguments: [
                "id": .string(id.uuidString),
                "content": .string("Updated content."),
            ]
        )

        let result = try await registry.call(name: "memory_recent", arguments: nil)
        let text = result.content.firstText
        #expect(text.contains("Updated content."))
        #expect(text.contains("Coffee preference"))
        #expect(text.contains("\"preference\""))
        #expect(text.contains("\"coffee\""))
    }

    @Test("memory_update with explicit empty tags clears the tag list")
    func updateClearsTagsOnExplicitEmptyArray() async throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let id = try await storeAndExtractID(
            registry,
            content: "Body.",
            tags: ["a", "b"]
        )
        _ = try await registry.call(
            name: "memory_update",
            arguments: [
                "id": .string(id.uuidString),
                "tags": .array([]),
            ]
        )

        let result = try await registry.call(name: "memory_recent", arguments: nil)
        let text = result.content.firstText
        // The recent JSON should contain an empty tags array now.
        #expect(text.contains("\"tags\":[]"))
    }

    @Test("memory_update writes a memory_update activity row")
    func updateWritesActivityRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let database = try LocalmemDatabase(url: tmp)
        let store = MemoryStore(database: database)
        let activityStore = ActivityStore(database: database)
        let identity = MCPClientIdentity(fallback: "test-client")
        let registry = ToolRegistry(store: store, activityStore: activityStore, identity: identity)

        let id = try await storeAndExtractID(registry, content: "x")
        _ = try await registry.call(
            name: "memory_update",
            arguments: [
                "id": .string(id.uuidString),
                "content": .string("y"),
            ]
        )

        let rows = try await activityStore.recent(limit: 10)
        #expect(rows.map(\.operation).contains("memory_update"))
        #expect(rows.first(where: { $0.operation == "memory_update" })?.actorID == "test-client")
    }

    @Test("MCP reads hide memories excluded for the client")
    func mcpReadsFilterExcludedMemories() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let database = try LocalmemDatabase(url: tmp)
        let store = MemoryStore(database: database)
        let activityStore = ActivityStore(database: database)
        let identity = MCPClientIdentity(fallback: "test-client")
        let registry = ToolRegistry(store: store, activityStore: activityStore, identity: identity)

        _ = try await store.add(
            content: "hidden searchable",
            type: .note,
            excludedAgents: ["test-client"],
            actorKind: .cli,
            actorID: "user"
        )
        _ = try await store.add(
            content: "visible searchable",
            type: .note,
            actorKind: .cli,
            actorID: "user"
        )

        let search = try await registry.call(
            name: "memory_search",
            arguments: ["query": .string("searchable")]
        ).content.firstText
        #expect(search.contains("visible searchable"))
        #expect(!search.contains("hidden searchable"))

        let recent = try await registry.call(name: "memory_recent", arguments: nil).content.firstText
        #expect(recent.contains("visible searchable"))
        #expect(!recent.contains("hidden searchable"))

        let rows = try await activityStore.recent(limit: 10)
        let filtered = rows.filter { $0.operation == "access_filtered" }
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.actorID == "test-client" })
        #expect(filtered.allSatisfy { $0.resultCount == 1 })
    }

    @Test("MCP update cannot edit a memory excluded for the client")
    func updateDeniedForExcludedMemory() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let database = try LocalmemDatabase(url: tmp)
        let store = MemoryStore(database: database)
        let activityStore = ActivityStore(database: database)
        let identity = MCPClientIdentity(fallback: "test-client")
        let registry = ToolRegistry(store: store, activityStore: activityStore, identity: identity)

        let memory = try await store.add(
            content: "do not edit",
            type: .note,
            excludedAgents: ["test-client"],
            actorKind: .cli,
            actorID: "user"
        )

        await #expect(throws: MCPError.self) {
            _ = try await registry.call(
                name: "memory_update",
                arguments: [
                    "id": .string(memory.id.uuidString),
                    "content": .string("edited"),
                ]
            )
        }
        let admin = try await store.get(id: memory.id)
        #expect(admin?.content == "do not edit")

        let rows = try await activityStore.recent(limit: 10)
        let blocked = rows.first { $0.operation == "access_blocked" }
        #expect(blocked?.actorID == "test-client")
        #expect(blocked?.memoryID == memory.id)
    }

    @Test("MCP JSON omits excludedAgents metadata")
    func mcpJSONOmitsExclusionMetadata() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let database = try LocalmemDatabase(url: tmp)
        let store = MemoryStore(database: database)
        let activityStore = ActivityStore(database: database)
        let identity = MCPClientIdentity(fallback: "test-client")
        let registry = ToolRegistry(store: store, activityStore: activityStore, identity: identity)

        _ = try await store.add(
            content: "visible with policy",
            type: .note,
            excludedAgents: ["other-client"],
            actorKind: .cli,
            actorID: "user"
        )

        let text = try await registry.call(name: "memory_recent", arguments: nil).content.firstText
        #expect(text.contains("visible with policy"))
        #expect(!text.contains("excludedAgents"))
        #expect(!text.contains("other-client"))
    }
}

// MARK: - Test helpers

private extension Array where Element == Tool.Content {
    /// Pull the first `.text(...)` payload out of a CallTool.Result's content array.
    /// All three handlers return exactly one `.text` content; tests assert against it.
    var firstText: String {
        for item in self {
            if case let .text(text, _, _) = item { return text }
        }
        return ""
    }
}
