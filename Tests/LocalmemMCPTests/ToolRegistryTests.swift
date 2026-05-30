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

    @Test("toolDescriptors lists exactly the three MCP tools")
    func descriptorsCoverAllTools() throws {
        let (registry, tmp) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let names = Set(registry.toolDescriptors.map(\.name))
        #expect(names == ["memory_store", "memory_search", "memory_recent"])
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
