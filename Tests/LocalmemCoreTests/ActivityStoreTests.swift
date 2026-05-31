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
            actorID: ".user"
        )

        let rows = try await activityStore.recent(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.operation == "memory_store")
        #expect(rows.first?.memoryID == memory.id)
    }

    @Test func deleteAddsActivityInSameOperation() async throws {
        let (store, activityStore, url) = try makeStores()
        defer { try? FileManager.default.removeItem(at: url) }

        let memory = try await store.add(content: "delete me", type: .note, actorKind: .cli, actorID: ".user")
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
}
