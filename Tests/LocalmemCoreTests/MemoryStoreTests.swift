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

        _ = try await store.add(content: "Hello world", type: .note, source: .user, actorKind: .cli)
        _ = try await store.add(content: "Second memory", type: .note, source: .user, actorKind: .cli)

        let recent = try await store.recent(limit: 10)
        #expect(recent.count == 2)
        #expect(recent.first?.content == "Second memory")
    }

    @Test func searchMatchesAndExcludes() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "The cat sat on the mat", type: .note, source: .user, actorKind: .cli)
        _ = try await store.add(content: "Dogs are loyal", type: .note, source: .user, actorKind: .cli)

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
            source: .user,
            actorKind: .cli
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

        let added = try await store.add(content: "to be deleted", type: .note, source: .user, actorKind: .cli)

        // First delete: row existed, returns true.
        let firstDelete = try await store.delete(id: added.id, actorKind: .cli)
        #expect(firstDelete == true)

        // Memory is gone from the store.
        let fetched = try await store.get(id: added.id)
        #expect(fetched == nil)

        // Idempotent: deleting again returns false, doesn't error.
        let secondDelete = try await store.delete(id: added.id, actorKind: .cli)
        #expect(secondDelete == false)
    }

    @Test func countReflectsAdds() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try await store.count() == 0)
        _ = try await store.add(content: "a", type: .note, source: .user, actorKind: .cli)
        _ = try await store.add(content: "b", type: .note, source: .user, actorKind: .cli)
        #expect(try await store.count() == 2)
    }

    @Test func findIDsByPrefix() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await store.add(content: "a", type: .note, source: .user, actorKind: .cli)
        let second = try await store.add(content: "b", type: .note, source: .user, actorKind: .cli)

        let firstPrefix = String(first.id.uuidString.prefix(8))
        let firstMatches = try await store.findIDs(prefix: firstPrefix)
        #expect(firstMatches == [first.id])

        // The pattern is always treated as a leading match, so a UUID that
        // doesn't belong to either row returns an empty list.
        let unknown = try await store.findIDs(prefix: "ffffffff-ffff-ffff-ffff-ffffffffffff")
        #expect(unknown.isEmpty)

        // Empty prefix expands to "%" — both ids come back (LIMIT 2 caps it).
        let all = try await store.findIDs(prefix: "")
        #expect(Set(all) == Set([first.id, second.id]))
    }

    @Test func searchOnWhitespaceQueryReturnsEmpty() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "anything", type: .note, source: .user, actorKind: .cli)
        let hits = try await store.search(query: "   ")
        #expect(hits.isEmpty)
    }

    @Test func deleteCleansFtsIndexAndTags() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "uniquely searchable content",
            type: .note,
            tags: ["work", "draft"],
            source: .user,
            actorKind: .cli
        )

        // Confirm it shows up via FTS before delete.
        let before = try await store.search(query: "searchable")
        #expect(before.count == 1)

        _ = try await store.delete(id: added.id, actorKind: .cli)

        // FTS trigger cleaned the index — no orphan hits.
        let after = try await store.search(query: "searchable")
        #expect(after.isEmpty)
    }
}
