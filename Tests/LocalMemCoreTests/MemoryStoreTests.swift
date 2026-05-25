import Testing
import Foundation
@testable import LocalMemCore

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
}
