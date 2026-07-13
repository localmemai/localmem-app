import Testing
import Foundation
import GRDB
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

        _ = try await store.add(content: "Hello world", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "Second memory", type: .note, actorKind: .cli, actorID: "user")

        let recent = try await store.recent(limit: 10)
        #expect(recent.count == 2)
        #expect(recent.first?.content == "Second memory")
    }

    @Test func searchMatchesAndExcludes() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "The cat sat on the mat", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "Dogs are loyal", type: .note, actorKind: .cli, actorID: "user")

        let hits = try await store.search(query: "cat")
        #expect(hits.count == 1)
        #expect(hits.first?.content.contains("cat") == true)

        let misses = try await store.search(query: "elephant")
        #expect(misses.isEmpty)
    }

    @Test func searchMatchesTags() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // The semantic-bridge case: neither title nor content mentions "coffee",
        // only the tags do. Search must still surface it.
        let memory = try await store.add(
            content: "Prefers flat white with oat milk.",
            type: .preference,
            title: "Morning drink",
            tags: ["coffee", "drink", "morning_routine"],
            actorKind: .cli, actorID: "user"
        )
        #expect(try await store.search(query: "coffee").map(\.id) == [memory.id])
        // snake_case tags tokenize on the underscore, so the broad term hits too.
        #expect(try await store.search(query: "routine").map(\.id) == [memory.id])
    }

    @Test func updateReindexesTagsForSearch() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let memory = try await store.add(
            content: "Prefers flat white with oat milk.",
            type: .preference,
            tags: ["coffee"],
            actorKind: .cli, actorID: "user"
        )
        _ = try await store.update(
            id: memory.id,
            content: memory.content,
            type: memory.type,
            tags: ["espresso"],
            actorKind: .cli, actorID: "user"
        )
        // The replaced tag stops matching; the new one starts.
        #expect(try await store.search(query: "coffee").isEmpty)
        #expect(try await store.search(query: "espresso").map(\.id) == [memory.id])

        // And a deleted memory's tags leave the index with it.
        _ = try await store.delete(id: memory.id, actorKind: .cli, actorID: "user")
        #expect(try await store.search(query: "espresso").isEmpty)
    }

    @Test func getById() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "Coffee order: flat white, oat milk",
            type: .preference,
            title: "Coffee",
            tags: ["coffee", "preferences"],
            actorKind: .cli,
            actorID: "user"
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

        let added = try await store.add(content: "to be deleted", type: .note, actorKind: .cli, actorID: "user")

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

    @Test func allReturnsEveryMemoryNewestFirst() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "first", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "second", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "third", type: .note, actorKind: .cli, actorID: "user")

        let all = try await store.all()
        #expect(all.count == 3)
        #expect(all.first?.content == "third")
        #expect(all.last?.content == "first")
    }

    @Test func importPreservesFieldsAndSkipsDuplicates() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // A memory that already lives in the target store.
        let existing = try await store.add(content: "already here", type: .note, actorKind: .cli, actorID: "user")

        // An archive carrying the existing memory plus one brand-new one, each
        // with its own id/timestamps/tags to prove full-fidelity transfer.
        let incoming = Memory(
            type: .preference,
            title: "Editor",
            content: "Uses Cursor.",
            tags: ["editor", "tools"],
            excludedAgents: ["blocked-agent"],
            source: "other-machine",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let duplicate = Memory(
            id: existing.id,
            type: .note,
            content: "conflicting content that must NOT overwrite",
            source: "other-machine"
        )

        let summary = try await store.importMemories([incoming, duplicate], actorKind: .cli, actorID: "user")
        #expect(summary.imported == 1)
        #expect(summary.skipped == 1)

        // The new memory landed with every field intact.
        let fetched = try #require(try await store.get(id: incoming.id))
        #expect(fetched.title == "Editor")
        #expect(fetched.content == "Uses Cursor.")
        #expect(Set(fetched.tags) == ["editor", "tools"])
        #expect(fetched.excludedAgents == ["blocked-agent"])
        #expect(fetched.source == "other-machine")
        #expect(fetched.createdAt == incoming.createdAt)

        // The duplicate id was left untouched, not clobbered.
        let untouched = try #require(try await store.get(id: existing.id))
        #expect(untouched.content == "already here")
    }

    @Test func importOfEmptyArchiveIsNoOp() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await store.importMemories([], actorKind: .cli, actorID: "user")
        #expect(summary.imported == 0)
        #expect(summary.skipped == 0)
        #expect(try await store.count() == 0)
    }

    /// Full transfer-between-machines flow: populate one vault, export it to a
    /// JSON file on disk, then import that file into a fresh, empty vault and
    /// assert every memory survived byte-for-byte. Mirrors exactly what the
    /// app's `exportArchive()` / `importArchive()` do (`all()` → encode → file →
    /// decode → `importMemories`), so this guards the whole feature end to end.
    @Test func exportToFileThenImportReproducesVaultExactly() async throws {
        let (source, sourceURL) = try makeStore()
        let (destination, destURL) = try makeStore()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("localmem-export-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destURL)
            try? FileManager.default.removeItem(at: file)
        }

        // A vault with the full spread of fields: tags, per-agent exclusions,
        // every memory type, an untitled note, and multi-byte content.
        _ = try await source.add(
            content: "Prefers flat white with oat milk. ☕️",
            type: .preference,
            title: "Coffee",
            tags: ["coffee", "drink"],
            excludedAgents: ["nosy-agent"],
            actorKind: .cli,
            actorID: "user"
        )
        _ = try await source.add(
            content: "Ship the import/export feature.",
            type: .project,
            title: "Q3 goal",
            tags: ["work"],
            actorKind: .cli,
            actorID: "user"
        )
        _ = try await source.add(content: "A plain untitled note", type: .note, actorKind: .cli, actorID: "user")

        // Export → bytes on disk → read back (the "carry the file to another Mac" hop).
        let exported = try MemoryArchive.encode(try await source.all())
        try exported.write(to: file, options: .atomic)
        let reloaded = try Data(contentsOf: file)
        let decoded = try MemoryArchive.decode(reloaded)

        // Import into the empty destination vault.
        let summary = try await destination.importMemories(decoded, actorKind: .cli, actorID: "user")
        #expect(summary.imported == 3)
        #expect(summary.skipped == 0)

        // The destination is now an exact replica of the source: same ids,
        // fields, tags, exclusions, and (fractional-second) timestamps. Memory's
        // Equatable + the store's stable ordering make this a strict check.
        let original = try await source.all()
        let restored = try await destination.all()
        #expect(restored == original)

        // Re-importing the same file is idempotent — nothing duplicated.
        let second = try await destination.importMemories(decoded, actorKind: .cli, actorID: "user")
        #expect(second.imported == 0)
        #expect(second.skipped == 3)
        #expect(try await destination.count() == 3)
    }

    @Test func sourceMirrorsActorID() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "marker",
            type: .note,
            actorKind: .cli,
            actorID: "user"
        )
        #expect(added.source == "user")

        let fetched = try await store.get(id: added.id)
        #expect(fetched?.source == "user")
    }

    @Test func countReflectsAdds() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try await store.count() == 0)
        _ = try await store.add(content: "a", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "b", type: .note, actorKind: .cli, actorID: "user")
        #expect(try await store.count() == 2)
    }

    @Test func findIDsByPrefix() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await store.add(content: "a", type: .note, actorKind: .cli, actorID: "user")
        let second = try await store.add(content: "b", type: .note, actorKind: .cli, actorID: "user")

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

        _ = try await store.add(content: "anything", type: .note, actorKind: .cli, actorID: "user")
        let hits = try await store.search(query: "   ")
        #expect(hits.isEmpty)
    }

    @Test func searchMatchesPartialPrefix() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "Loves coffee.", type: .preference,
                                title: "Coffee preference", actorKind: .cli, actorID: "user")

        // Live-typing scenario: user types "cof" — must hit "coffee" already.
        let prefix = try await store.search(query: "cof")
        #expect(prefix.count == 1)

        // Multi-token AND: "cof pref" hits the same memory because the
        // title contains words starting with both prefixes.
        let multi = try await store.search(query: "cof pref")
        #expect(multi.count == 1)

        // Non-matching prefix returns nothing.
        let miss = try await store.search(query: "xyz")
        #expect(miss.isEmpty)
    }

    @Test func updateMutatesFieldsAndRetagsAtomically() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = try await store.add(
            content: "Likes flat white.",
            type: .preference,
            title: "Coffee preference",
            tags: ["coffee", "preference"],
            actorKind: .cli,
            actorID: "user"
        )

        let updated = try await store.update(
            id: original.id,
            content: "Loves oat-milk flat white.",
            type: .preference,
            title: "Coffee preference",
            tags: ["coffee", "drink", "morning_routine"],
            actorKind: .cli,
            actorID: "user"
        )

        // Mutable fields changed; id and createdAt preserved (tolerance for
        // the ISO8601 round-trip's millisecond truncation).
        #expect(updated.id == original.id)
        #expect(abs(updated.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
        #expect(updated.content == "Loves oat-milk flat white.")
        #expect(updated.updatedAt > original.updatedAt)
        #expect(Set(updated.tags) == ["coffee", "drink", "morning_routine"])

        // FTS index reflects the new content (new word "oat-milk").
        let hits = try await store.search(query: "oat")
        #expect(hits.first?.id == original.id)

        // Old tag no longer attached.
        let fetched = try await store.get(id: original.id)
        #expect(fetched?.tags.contains("preference") == false)
    }

    @Test func updateThrowsNotFoundForMissingMemory() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: MemoryStoreError.notFound) {
            try await store.update(
                id: UUID(),
                content: "anything",
                type: .note,
                actorKind: .cli
            )
        }
    }

    @Test func searchStripsFTSOperatorsFromUserInput() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "coffee", type: .note, actorKind: .cli, actorID: "user")

        // Operators in user input must not blow up FTS5 parsing — they are
        // stripped and the rest of the query still works.
        let hits = try await store.search(query: "coffee*(:^)")
        #expect(hits.count == 1)
    }

    @Test func deleteCleansFtsIndexAndTags() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "uniquely searchable content",
            type: .note,
            tags: ["work", "draft"],
            actorKind: .cli,
            actorID: "user"
        )

        // Confirm it shows up via FTS before delete.
        let before = try await store.search(query: "searchable")
        #expect(before.count == 1)

        _ = try await store.delete(id: added.id, actorKind: .cli)

        // FTS trigger cleaned the index — no orphan hits.
        let after = try await store.search(query: "searchable")
        #expect(after.isEmpty)
    }

    @Test func exclusionsRoundTripAndFilterReads() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "Private coffee note",
            type: .note,
            excludedAgents: ["codex", " cursor ", "codex"],
            actorKind: .cli,
            actorID: "user"
        )

        let admin = try await store.get(id: added.id)
        #expect(admin?.excludedAgents == ["codex", "cursor"])

        let hidden = try await store.get(id: added.id, requestingAgent: "codex")
        #expect(hidden == nil)

        let visible = try await store.get(id: added.id, requestingAgent: "claude-code")
        #expect(visible?.id == added.id)
    }

    @Test func recentAndSearchApplyExclusionsBeforeLimit() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(
            content: "alpha",
            type: .note,
            excludedAgents: ["codex"],
            actorKind: .cli,
            actorID: "user"
        )
        let visible = try await store.add(
            content: "alpha bravo",
            type: .note,
            actorKind: .cli,
            actorID: "user"
        )

        let searchHits = try await store.search(query: "alpha", limit: 1, requestingAgent: "codex")
        #expect(searchHits.map(\.id) == [visible.id])

        let recent = try await store.recent(limit: 10, requestingAgent: "codex")
        #expect(recent.map(\.content).contains("alpha") == false)
        #expect(recent.map(\.id).contains(visible.id))
    }

    @Test func unknownAgentsRemainDefaultOpen() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "Visible to future agents",
            type: .note,
            actorKind: .cli,
            actorID: "user"
        )

        let visible = try await store.get(id: added.id, requestingAgent: "future-agent")
        #expect(visible?.id == added.id)
    }

    @Test func updatePreservesExclusionsUnlessReplacementProvided() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "Original",
            type: .note,
            excludedAgents: ["codex"],
            actorKind: .cli,
            actorID: "user"
        )

        let preserved = try await store.update(
            id: added.id,
            content: "Updated",
            type: .note,
            actorKind: .cli,
            actorID: "user"
        )
        #expect(preserved.excludedAgents == ["codex"])

        let replaced = try await store.update(
            id: added.id,
            content: "Updated again",
            type: .note,
            excludedAgents: ["cursor"],
            actorKind: .cli,
            actorID: "user"
        )
        #expect(replaced.excludedAgents == ["cursor"])
    }

    @Test func findIDsRespectsRequestingAgentExclusion() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let hidden = try await store.add(
            content: "hidden from codex",
            type: .note,
            excludedAgents: ["codex"],
            actorKind: .cli,
            actorID: "user"
        )

        // Without a requesting agent, the admin path sees everything.
        let adminMatches = try await store.findIDs(prefix: String(hidden.id.uuidString.prefix(8)))
        #expect(adminMatches.contains(hidden.id))

        // From codex's perspective the same prefix returns nothing.
        let codexMatches = try await store.findIDs(
            prefix: String(hidden.id.uuidString.prefix(8)),
            requestingAgent: "codex"
        )
        #expect(codexMatches.contains(hidden.id) == false)
    }

    @Test func updateWithEmptyExclusionsClearsTheList() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(
            content: "Initially restricted",
            type: .note,
            excludedAgents: ["codex", "cursor"],
            actorKind: .cli,
            actorID: "user"
        )
        // Sanity: stored exclusions made it in normalised + sorted.
        #expect(added.excludedAgents == ["codex", "cursor"])

        // Passing `[]` is a deliberate "clear" — different from passing nil
        // which preserves whatever was there.
        let cleared = try await store.update(
            id: added.id,
            content: "Now public",
            type: .note,
            excludedAgents: [],
            actorKind: .cli,
            actorID: "user"
        )
        #expect(cleared.excludedAgents.isEmpty)

        // The previously-excluded agent now sees the memory.
        let codexView = try await store.get(id: added.id, requestingAgent: "codex")
        #expect(codexView?.id == added.id)
    }

    @Test func addNormalizesEmptyAndWhitespaceExclusionStrings() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // The store should silently drop empty strings, whitespace, and
        // duplicates — the normalization function lives in MemoryStore and
        // is reachable through `add`/`update`'s public surface only.
        let added = try await store.add(
            content: "trimmed exclusions",
            type: .note,
            excludedAgents: ["", "   ", " codex ", "codex"],
            actorKind: .cli,
            actorID: "user"
        )
        #expect(added.excludedAgents == ["codex"])
    }

    @Test func deleteCascadesExclusions() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let database = try LocalmemDatabase(url: tmp)
        let store = MemoryStore(database: database)
        let added = try await store.add(
            content: "Delete me",
            type: .note,
            excludedAgents: ["codex"],
            actorKind: .cli,
            actorID: "user"
        )

        _ = try await store.delete(id: added.id, actorKind: .cli, actorID: "user")

        let rows = try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_agent_exclusions WHERE memory_id = ?",
                arguments: [added.id.uuidString]
            ) ?? 0
        }
        #expect(rows == 0)
    }

    // MARK: - Agent-centric access management

    @Test func memoriesExcludingListsBlockedForAgent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let hidden = try await store.add(content: "hidden from codex", type: .note,
                                         excludedAgents: ["codex"], actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "visible to all", type: .note, actorKind: .cli, actorID: "user")

        let blocked = try await store.memoriesExcluding(agent: "codex")
        #expect(blocked.map(\.id) == [hidden.id])
        #expect(try await store.memoriesExcluding(agent: "cursor").isEmpty)
    }

    @Test func blockedCountsReportFilteredReads() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "alpha hidden", type: .note,
                                excludedAgents: ["codex"], actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "alpha visible", type: .note,
                                actorKind: .cli, actorID: "user")

        #expect(try await store.blockedRecentCount(limit: 10, requestingAgent: "codex") == 1)
        #expect(try await store.blockedSearchCount(query: "alpha", limit: 10, requestingAgent: "codex") == 1)
        #expect(try await store.blockedSearchCount(query: "alpha", limit: 10, requestingAgent: "cursor") == 0)
    }

    @Test func setExclusionTogglesSingleAgent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let m = try await store.add(content: "toggle me", type: .note, actorKind: .cli, actorID: "user")

        #expect(try await store.setExclusion(memoryID: m.id, agent: "cursor", excluded: true, actorKind: .cli, actorID: "user"))
        #expect(try await store.get(id: m.id, requestingAgent: "cursor") == nil)

        // Idempotent re-add reports no change.
        #expect(try await store.setExclusion(memoryID: m.id, agent: "cursor", excluded: true, actorKind: .cli, actorID: "user") == false)

        #expect(try await store.setExclusion(memoryID: m.id, agent: "cursor", excluded: false, actorKind: .cli, actorID: "user"))
        #expect(try await store.get(id: m.id, requestingAgent: "cursor")?.id == m.id)
    }

    @Test func grantAllAccessClearsAgentEverywhere() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "a", type: .note, excludedAgents: ["codex"], actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "b", type: .note, excludedAgents: ["codex", "cursor"], actorKind: .cli, actorID: "user")

        let cleared = try await store.grantAllAccess(toAgent: "codex", actorKind: .cli, actorID: "user")
        #expect(cleared == 2)
        #expect(try await store.memoriesExcluding(agent: "codex").isEmpty)
        // Other agents' exclusions untouched.
        #expect(try await store.memoriesExcluding(agent: "cursor").count == 1)
    }

    @Test func accessMethodsIgnoreBlankAgent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let m = try await store.add(content: "x", type: .note, actorKind: .cli, actorID: "user")
        // Empty / whitespace agent ids are no-ops, never partial writes.
        #expect(try await store.memoriesExcluding(agent: "   ").isEmpty)
        #expect(try await store.setExclusion(memoryID: m.id, agent: "", excluded: true, actorKind: .cli, actorID: "user") == false)
        #expect(try await store.grantAllAccess(toAgent: "  ", actorKind: .cli, actorID: "user") == 0)
        #expect(try await store.revokeAllAccess(fromAgent: "", actorKind: .cli, actorID: "user") == 0)
        // The memory is still visible to everyone — nothing was excluded.
        #expect(try await store.get(id: m.id, requestingAgent: "codex")?.id == m.id)
    }

    @Test func revokeAllAccessExcludesAgentFromEveryMemory() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "a", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "b", type: .note, excludedAgents: ["cursor"], actorKind: .cli, actorID: "user")

        let added = try await store.revokeAllAccess(fromAgent: "cursor", actorKind: .cli, actorID: "user")
        #expect(added == 1) // only the memory that didn't already exclude cursor
        #expect(try await store.memoriesExcluding(agent: "cursor").count == 2)
        #expect(try await store.recent(limit: 10, requestingAgent: "cursor").isEmpty)
    }
}
