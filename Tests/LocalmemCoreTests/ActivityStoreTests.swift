import Foundation
import Testing
@testable import LocalmemCore

@Suite("ActivityStore")
struct ActivityStoreTests {
    func makeStores() throws -> (MemoryStore, ActivityStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        let database = try LocalmemDatabase(url: tmp)
        return (MemoryStore(database: database), ActivityStore(database: database), tmp)
    }

    @Test func recordAndReadRecent() async throws {
        let (store, activityStore, url) = try makeStores()
        defer { try? FileManager.default.removeItem(at: url) }

        let memory = try await store.add(
            content: "activity trail",
            type: .note,
            actorKind: .cli,
            actorID: "user"
        )

        let rows = try await activityStore.recent(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.operation == "memory_store")
        #expect(rows.first?.memoryID == memory.id)
    }

    @Test func deleteAddsActivityInSameOperation() async throws {
        let (store, activityStore, url) = try makeStores()
        defer { try? FileManager.default.removeItem(at: url) }

        let memory = try await store.add(content: "delete me", type: .note, actorKind: .cli, actorID: "user")
        let existed = try await store.delete(
            id: memory.id,
            actorKind: .cli
        )

        #expect(existed == true)
        let rows = try await activityStore.recent(limit: 10)
        #expect(rows.count == 2)
        #expect(rows.first?.operation == "memory_delete")
        #expect(rows.first?.memoryID == memory.id)
    }

    /// The instance `add(_:)` is the surface read-only operations (memory_recent,
    /// memory_search) use to record their activity. The static `add(_:in:)` is
    /// already exercised through MemoryStore writes — this test pins the
    /// stand-alone path that has its own `database.write` envelope.
    @Test func instanceAddPersistsAndPreservesAllFields() async throws {
        let (_, activityStore, url) = try makeStores()
        defer { try? FileManager.default.removeItem(at: url) }

        let activity = Activity(
            actorKind: .mcp,
            actorID: "claude-code",
            operation: "memory_search",
            query: "coffee",
            resultCount: 7
        )
        try await activityStore.add(activity)

        let rows = try await activityStore.recent(limit: 10)
        #expect(rows.count == 1)
        let saved = try #require(rows.first)
        #expect(saved.id == activity.id)
        #expect(saved.actorKind == .mcp)
        #expect(saved.actorID == "claude-code")
        #expect(saved.operation == "memory_search")
        #expect(saved.query == "coffee")
        #expect(saved.resultCount == 7)
    }

    /// `recent(limit:)` clamps a non-positive limit to 1 so callers can't ask
    /// SQLite for `LIMIT 0` (which would silently swallow rows) or a negative
    /// value.
    @Test func recentClampsNonPositiveLimit() async throws {
        let (store, activityStore, url) = try makeStores()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "one", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "two", type: .note, actorKind: .cli, actorID: "user")

        let zero = try await activityStore.recent(limit: 0)
        #expect(zero.count == 1)

        let negative = try await activityStore.recent(limit: -10)
        #expect(negative.count == 1)
    }
}
