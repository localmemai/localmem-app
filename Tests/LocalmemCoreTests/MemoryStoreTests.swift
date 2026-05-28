import Testing
import Foundation
@testable import LocalmemCore

@Suite("MemoryStore")
struct MemoryStoreTests {
    func makeStore() throws -> (MemoryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        return (try MemoryStore(databaseURL: tmp), tmp)
    }

    @Test func addAndRecent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "Hello world",   type: .note, source: .user)
        _ = try await store.add(content: "Second memory", type: .note, source: .user)

        let recent = try await store.recent(limit: 10)
        #expect(recent.count == 2)
        #expect(recent.first?.content == "Second memory")
    }

    @Test func searchMatchesAndExcludes() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "The cat sat on the mat", type: .note, source: .user)
        _ = try await store.add(content: "Dogs are loyal",          type: .note, source: .user)

        let hits = try await store.search(query: "cat")
        #expect(hits.count == 1)
        #expect(hits.first?.content.contains("cat") == true)

        let misses = try await store.search(query: "elephant")
        #expect(misses.isEmpty)
    }

    @Test func getById() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "Coffee order: flat white, oat milk",
            type: .preference,
            title: "Coffee",
            tags: ["coffee", "preferences"],
            source: .user
        )

        let fetched = try await store.get(id: added.id)
        #expect(fetched != nil)
        #expect(fetched?.content == added.content)
        #expect(fetched?.title == "Coffee")
        #expect(fetched?.type == .preference)
        #expect(Set(fetched?.tags ?? []) == ["coffee", "preferences"])
    }

    @Test func deleteRemovesMemoryAndIsIdempotent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(content: "to be deleted", type: .note, source: .user)

        // First delete: row existed, returns true.
        let firstDelete = try await store.delete(id: added.id)
        #expect(firstDelete == true)

        // Memory is gone from the store.
        let fetched = try await store.get(id: added.id)
        #expect(fetched == nil)

        // Idempotent: deleting again returns false, doesn't error.
        let secondDelete = try await store.delete(id: added.id)
        #expect(secondDelete == false)
    }

    @Test func deleteCleansFtsIndexAndTags() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "uniquely searchable content",
            type: .note,
            tags: ["work", "draft"],
            source: .user
        )

        // Confirm it shows up via FTS before delete.
        let before = try await store.search(query: "searchable")
        #expect(before.count == 1)

        _ = try await store.delete(id: added.id)

        // FTS trigger cleaned the index — no orphan hits.
        let after = try await store.search(query: "searchable")
        #expect(after.isEmpty)
    }
}
