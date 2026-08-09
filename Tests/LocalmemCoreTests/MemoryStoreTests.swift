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

        let recent = try await store.recent(limit: 10).memories
        #expect(recent.count == 2)
        #expect(recent.first?.content == "") // Compact index has no content
        
        let full = try await store.get(id: recent.first!.id)
        #expect(full?.content == "Second memory") // Full body fetched
    }

    @Test func searchMatchesAndExcludes() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "The cat sat on the mat", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "Dogs are loyal", type: .note, actorKind: .cli, actorID: "user")

        let hits = try await store.search(query: "cat").memories
        #expect(hits.count == 1)
        #expect(hits.first?.content == "") // Compact index has no content
        
        let full = try await store.get(id: hits.first!.id)
        #expect(full?.content.contains("cat") == true) // Full body fetched

        let misses = try await store.search(query: "elephant").memories
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
        #expect(try await store.search(query: "coffee").memories.map(\.id) == [memory.id])
        // snake_case tags tokenize on the underscore, so the broad term hits too.
        #expect(try await store.search(query: "routine").memories.map(\.id) == [memory.id])
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
        #expect(try await store.search(query: "coffee").memories.isEmpty)
        #expect(try await store.search(query: "espresso").memories.map(\.id) == [memory.id])

        // And a deleted memory's tags leave the index with it.
        _ = try await store.delete(id: memory.id, actorKind: .cli, actorID: "user")
        #expect(try await store.search(query: "espresso").memories.isEmpty)
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

        // A vault with the full spread of fields: tags, every memory type,
        // an untitled note, and multi-byte content.
        _ = try await source.add(
            content: "Prefers flat white with oat milk. ☕️",
            type: .preference,
            title: "Coffee",
            tags: ["coffee", "drink"],
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
        // fields, tags, exclusions, and (fractional-second) timestamps. Compare
        // id-sorted rather than in `all()` order: `all()` breaks a created_at tie
        // by rowid (insertion order), which import legitimately reassigns, so the
        // two vaults can list a same-millisecond tie in a different order without
        // any data differing. Sorting by the stable, preserved `id` keeps this a
        // strict byte-for-byte fidelity check (via Memory's Equatable) without
        // asserting a cross-store array order that isn't a real invariant.
        let byID: (Memory, Memory) -> Bool = { $0.id.uuidString < $1.id.uuidString }
        let original = try await source.all().sorted(by: byID)
        let restored = try await destination.all().sorted(by: byID)
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
        let hits = try await store.search(query: "   ").memories
        #expect(hits.isEmpty)
    }

    @Test func searchMatchesPartialPrefix() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "Loves coffee.", type: .preference,
                                title: "Coffee preference", actorKind: .cli, actorID: "user")

        // Live-typing scenario: user types "cof" — must hit "coffee" already.
        let prefix = try await store.search(query: "cof").memories
        #expect(prefix.count == 1)

        // Multi-token AND: "cof pref" hits the same memory because the
        // title contains words starting with both prefixes.
        let multi = try await store.search(query: "cof pref").memories
        #expect(multi.count == 1)

        // Non-matching prefix returns nothing.
        let miss = try await store.search(query: "xyz").memories
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
        let hits = try await store.search(query: "oat").memories
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
        let hits = try await store.search(query: "coffee*(:^)").memories
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
        let before = try await store.search(query: "searchable").memories
        #expect(before.count == 1)

        _ = try await store.delete(id: added.id, actorKind: .cli)

        // FTS trigger cleaned the index — no orphan hits.
        let after = try await store.search(query: "searchable").memories
        #expect(after.isEmpty)
    }
    // MARK: - Folders and agent visibility

    private static let inboxID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    @Test func newMemoriesLandInInboxByDefault() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let m = try await store.add(content: "unfiled", type: .note, actorKind: .cli, actorID: "user")
        #expect(m.folderID == Self.inboxID)
    }

    @Test func inboxRejectsRenameDeleteAndSensitivity() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: FolderError.self) {
            _ = try await store.updateFolder(id: Self.inboxID, name: "Renamed", isSensitive: true)
        }
        await #expect(throws: FolderError.self) {
            try await store.deleteFolder(id: Self.inboxID)
        }
        // And it stays open after the failed attempt.
        let inbox = try #require(try await store.listFolders().first { $0.id == Self.inboxID })
        #expect(inbox.isSensitive == false)
        #expect(inbox.name == "Inbox")
    }

    @Test func sensitiveFoldersAreHiddenFromRestrictedAgentsOnly() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Finance", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        _ = try await store.add(content: "brokerage alpha", type: .fact,
                                folderID: secret.id, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "public alpha", type: .note,
                                actorKind: .cli, actorID: "user")

        try await store.setAgentStatus(id: "codex", status: .nonSensitiveOnly)

        // Restricted agent sees only the open memory, and is told one was held back.
        let restricted = try await store.search(query: "alpha", limit: 10, requestingAgent: "codex")
        #expect(restricted.memories.count == 1)
        #expect(restricted.memories.first?.folderID == Self.inboxID)
        #expect(restricted.withheld == 1)

        // An agent left at the default status sees both, with nothing withheld.
        let open = try await store.search(query: "alpha", limit: 10, requestingAgent: "cursor")
        #expect(open.memories.count == 2)
        #expect(open.withheld == 0)

        // recent applies the same filter.
        let recent = try await store.recent(limit: 10, requestingAgent: "codex")
        #expect(recent.memories.count == 1)
        #expect(recent.withheld == 1)
    }

    /// A search whose every match is sensitive returns nothing — and has to say
    /// so. This previously reported `withheld: 0`, because the empty-result
    /// early return threw the count away, so a fully blocked read was
    /// indistinguishable from one that simply found nothing. It is also the
    /// case that matters: the MCP server writes its `access_filtered` audit row
    /// only when this is greater than zero, so total denial left no trace.
    @Test func aFullyBlockedSearchStillReportsWhatWasWithheld() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Acme Corp", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        _ = try await store.add(content: "acme staging sits behind the VPN", type: .fact,
                                folderID: secret.id, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "acme renews at the end of Q3", type: .project,
                                folderID: secret.id, actorKind: .cli, actorID: "user")

        try await store.setAgentStatus(id: "cursor", status: .nonSensitiveOnly)

        let blocked = try await store.search(query: "acme", limit: 10, requestingAgent: "cursor")
        #expect(blocked.memories.isEmpty)
        #expect(blocked.withheld == 2)

        // The same query for an unrestricted agent: everything, nothing withheld.
        let allowed = try await store.search(query: "acme", limit: 10, requestingAgent: "claude-code")
        #expect(allowed.memories.count == 2)
        #expect(allowed.withheld == 0)
    }

    /// A query matching nothing at all must not claim anything was withheld —
    /// the fix above must not report the whole sensitive folder for an unrelated
    /// search.
    @Test func aSearchThatMatchesNothingWithholdsNothing() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Acme Corp", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        _ = try await store.add(content: "acme staging sits behind the VPN", type: .fact,
                                folderID: secret.id, actorKind: .cli, actorID: "user")
        try await store.setAgentStatus(id: "cursor", status: .nonSensitiveOnly)

        let miss = try await store.search(query: "zeppelin", limit: 10, requestingAgent: "cursor")
        #expect(miss.memories.isEmpty)
        #expect(miss.withheld == 0)
    }

    @Test func unknownAgentsDefaultToFullAccess() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Finance", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        _ = try await store.add(content: "brokerage", type: .fact,
                                folderID: secret.id, actorKind: .cli, actorID: "user")

        // An agent never seen before is `all` — installing a tool never hides anything.
        let hits = try await store.search(query: "brokerage", limit: 10,
                                          requestingAgent: "brand-new-agent")
        #expect(hits.memories.count == 1)
        #expect(hits.withheld == 0)
    }

    @Test func markingAFolderSensitiveReclassifiesItsContents() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let folder = try await store.createFolder(name: "Docs", kind: .manual,
                                                  projectRoot: nil, isSensitive: false)
        _ = try await store.add(content: "quarterly numbers", type: .fact,
                                folderID: folder.id, actorKind: .cli, actorID: "user")
        try await store.setAgentStatus(id: "codex", status: .nonSensitiveOnly)

        // Visible while the folder is open.
        #expect(try await store.search(query: "quarterly", limit: 10,
                                       requestingAgent: "codex").memories.count == 1)

        // Flipping the folder hides every memory in it — no per-memory work.
        _ = try await store.updateFolder(id: folder.id, name: "Docs", isSensitive: true)
        #expect(try await store.search(query: "quarterly", limit: 10,
                                       requestingAgent: "codex").memories.isEmpty)
    }

    @Test func movingAMemoryChangesWhoCanReadIt() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Private", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        let m = try await store.add(content: "movable", type: .note, actorKind: .cli, actorID: "user")
        try await store.setAgentStatus(id: "codex", status: .nonSensitiveOnly)

        #expect(try await store.search(query: "movable", limit: 10,
                                       requestingAgent: "codex").memories.count == 1)

        _ = try await store.update(id: m.id, content: "movable", type: .note,
                                   folderID: secret.id, actorKind: .cli, actorID: "user")
        #expect(try await store.search(query: "movable", limit: 10,
                                       requestingAgent: "codex").memories.isEmpty)
    }

    @Test func deletingAFolderReturnsItsMemoriesToInbox() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let folder = try await store.createFolder(name: "Temp", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        let m = try await store.add(content: "orphan", type: .note,
                                    folderID: folder.id, actorKind: .cli, actorID: "user")

        try await store.deleteFolder(id: folder.id)

        // The memory survives, refiled — and is open again, since Inbox is never sensitive.
        let fetched = try #require(try await store.get(id: m.id))
        #expect(fetched.folderID == Self.inboxID)
    }

    @Test func resolveProjectFolderIsIdempotentPerGitRoot() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try await store.resolveProjectFolder(gitRoot: "/tmp/work/api")
        let b = try await store.resolveProjectFolder(gitRoot: "/tmp/work/api")
        #expect(a.id == b.id)
        #expect(a.isSensitive == false) // auto-created folders are always open

        // Distinct roots that share a leaf name stay distinct folders.
        let other = try await store.resolveProjectFolder(gitRoot: "/tmp/personal/api")
        #expect(other.id != a.id)
    }

    // MARK: - Regressions

    @Test func mergingIntoTheNameOfASourceKeepsThatFolder() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let keep = try await store.createFolder(name: "Archive", kind: .manual,
                                                projectRoot: nil, isSensitive: false)
        let other = try await store.createFolder(name: "Old", kind: .manual,
                                                 projectRoot: nil, isSensitive: false)
        let a = try await store.add(content: "in archive", type: .note,
                                    folderID: keep.id, actorKind: .cli, actorID: "user")
        let b = try await store.add(content: "in old", type: .note,
                                    folderID: other.id, actorKind: .cli, actorID: "user")

        // Naming the destination after one of the sources previously deleted it,
        // dumping everything into Inbox.
        let dest = try await store.mergeFolders(ids: [keep.id, other.id], intoName: "Archive")
        #expect(dest.id == keep.id)

        let folders = try await store.listFolders()
        #expect(folders.contains { $0.id == keep.id })
        #expect(!folders.contains { $0.id == other.id })
        #expect(try await store.get(id: a.id)?.folderID == keep.id)
        #expect(try await store.get(id: b.id)?.folderID == keep.id)
    }

    @Test func mergingAppliesTheDestinationsSensitivity() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Private", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        let open = try await store.createFolder(name: "Notes", kind: .manual,
                                                projectRoot: nil, isSensitive: false)
        let m = try await store.add(content: "was private", type: .fact,
                                    folderID: secret.id, actorKind: .cli, actorID: "user")

        // Destination rule, same as moving a single memory: the folder the
        // memories land in defines their visibility, and merging never rewrites
        // the destination's own setting — that would change visibility for
        // memories already filed there that nobody touched.
        let dest = try await store.mergeFolders(ids: [secret.id], intoName: "Notes")
        #expect(dest.id == open.id)
        #expect(dest.isSensitive == false)
        let refreshed = try #require(try await store.listFolders().first { $0.id == dest.id })
        #expect(refreshed.isSensitive == false)
        #expect(try await store.get(id: m.id)?.folderID == open.id)

        // A restricted agent can now read it, because its folder is open.
        try await store.setAgentStatus(id: "codex", status: .nonSensitiveOnly)
        #expect(try await store.search(query: "private", limit: 10,
                                       requestingAgent: "codex").memories.count == 1)
    }

    @Test func mergingIntoANewFolderCarriesSensitivityForward() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Private", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        // A destination that does not exist yet has no rule to respect, so it
        // must not default open and widen access unannounced.
        let dest = try await store.mergeFolders(ids: [secret.id], intoName: "Archive")
        #expect(dest.isSensitive)
    }

    @Test func importingAnArchiveWithAnUnknownFolderFilesItInInbox() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // Archives carry memories but not folders, so the id names a row that
        // does not exist here. Writing it verbatim aborted the whole import on
        // the folder foreign key.
        let incoming = Memory(type: .fact, content: "from another machine",
                              folderID: UUID(), source: "other-machine")
        let summary = try await store.importMemories([incoming], actorKind: .cli, actorID: "user")
        #expect(summary.imported == 1)
        #expect(try await store.get(id: incoming.id)?.folderID == Self.inboxID)
    }

    @Test func withheldCountsOnlyCoverTheReturnedWindow() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Private", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        for i in 0..<10 {
            _ = try await store.add(content: "secret alpha \(i)", type: .fact,
                                    folderID: secret.id, actorKind: .cli, actorID: "user")
        }
        try await store.setAgentStatus(id: "codex", status: .nonSensitiveOnly)

        // A full-table count reported every sensitive memory in the vault,
        // regardless of how few rows the caller asked for.
        let recent = try await store.recent(limit: 3, requestingAgent: "codex")
        #expect(recent.withheld <= 3)
        let hits = try await store.search(query: "alpha", limit: 3, requestingAgent: "codex")
        #expect(hits.withheld <= 3)
    }

    @Test func accessChangesAreRecordedInTheAuditLog() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let activity = ActivityStore(database: try LocalmemDatabase(url: url))

        let folder = try await store.createFolder(name: "Docs", kind: .manual,
                                                  projectRoot: nil, isSensitive: false)
        _ = try await store.updateFolder(id: folder.id, name: "Docs", isSensitive: true)
        try await store.setAgentStatus(id: "codex", status: .nonSensitiveOnly)

        let ops = Set(try await activity.recent(limit: 50).map(\.operation))
        #expect(ops.contains("folder_restrict"))
        #expect(ops.contains("agent_restrict"))
    }

    @Test func movingAMemoryAcrossASensitivityBoundaryIsAudited() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let activity = ActivityStore(database: try LocalmemDatabase(url: url))

        let secret = try await store.createFolder(name: "Private", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        let m = try await store.add(content: "movable", type: .note, actorKind: .cli, actorID: "user")

        // Inbox -> sensitive: the memory's readership narrows, so it is logged.
        #expect(try await store.moveMemories(ids: [m.id], toFolder: secret.id) == 1)
        #expect(try await store.get(id: m.id)?.folderID == secret.id)
        var ops = Set(try await activity.recent(limit: 50).map(\.operation))
        #expect(ops.contains("memory_restrict"))

        // And back again.
        _ = try await store.moveMemories(ids: [m.id], toFolder: Self.inboxID)
        ops = Set(try await activity.recent(limit: 50).map(\.operation))
        #expect(ops.contains("memory_open"))
    }

    @Test func movingWithinTheSameSensitivityIsNotAnAccessEvent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let activity = ActivityStore(database: try LocalmemDatabase(url: url))

        let a = try await store.createFolder(name: "A", kind: .manual, projectRoot: nil, isSensitive: false)
        let m = try await store.add(content: "plain", type: .note, actorKind: .cli, actorID: "user")

        // Inbox and A are both open, so this is pure organisation.
        _ = try await store.moveMemories(ids: [m.id], toFolder: a.id)
        let ops = Set(try await activity.recent(limit: 50).map(\.operation))
        #expect(!ops.contains("memory_restrict"))
        #expect(!ops.contains("memory_open"))
    }

    @Test func mergingASensitiveFolderIntoInboxLeavesInboxOpen() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let secret = try await store.createFolder(name: "Private", kind: .manual,
                                                  projectRoot: nil, isSensitive: true)
        _ = try await store.add(content: "secret", type: .fact,
                                folderID: secret.id, actorKind: .cli, actorID: "user")

        // Inbox is the guaranteed safe home. A merge must never flip it, or one
        // drag would hide the whole default folder from restricted agents.
        let dest = try await store.mergeFolders(ids: [secret.id], intoName: "Inbox")
        #expect(dest.isSensitive == false)
        let inbox = try #require(try await store.listFolders().first { $0.kind == .default })
        #expect(inbox.isSensitive == false)
    }

    // MARK: - Supersession

    @Test func addSupersedesHidesOldAndDeRanksWhenIncluded() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let old = try await store.add(content: "Old approach: use REST.", type: .decision,
                                      tags: ["arch"], actorKind: .cli, actorID: "user")
        let new = try await store.add(content: "New approach: use gRPC.", type: .decision,
                                      tags: ["arch"], supersedes: [old.id], actorKind: .cli, actorID: "user")

        // The returned superseding memory reflects the edge it created.
        #expect(new.supersedes == [old.id])
        // And the superseded memory is flagged as replaced.
        #expect(try await store.get(id: old.id)?.supersededBy == [new.id])

        // Default recent/search hide the superseded memory.
        #expect(try await store.recent(limit: 10).memories.map(\.id) == [new.id])
        #expect(try await store.search(query: "approach").memories.map(\.id) == [new.id])

        // includeSuperseded surfaces it, de-ranked below the live entry.
        let history = try await store.recent(limit: 10, requestingAgent: nil, includeSuperseded: true).memories
        #expect(history.map(\.id) == [new.id, old.id])
        let searchHistory = try await store.search(query: "approach", limit: 10,
                                                   requestingAgent: nil, includeSuperseded: true)
        #expect(searchHistory.memories.map(\.id) == [new.id, old.id])
    }

    @Test func supersedeMethodLinksAndHides() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let old = try await store.add(content: "first draft", type: .note, actorKind: .cli, actorID: "user")
        let new = try await store.add(content: "final draft", type: .note, actorKind: .cli, actorID: "user")

        try await store.supersede(supersededID: old.id, supersedingID: new.id, actorKind: .cli)

        #expect(try await store.recent(limit: 10).memories.map(\.id) == [new.id])
        #expect(try await store.get(id: old.id)?.supersededBy == [new.id])
        #expect(try await store.get(id: new.id)?.supersedes == [old.id])
    }

    @Test func supersedeRejectsSelfLink() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let m = try await store.add(content: "x", type: .note, actorKind: .cli, actorID: "user")
        await #expect(throws: MemoryStoreError.invalidSupersession) {
            try await store.supersede(supersededID: m.id, supersedingID: m.id, actorKind: .cli)
        }
        // The memory stays live — no self-loop was written.
        #expect(try await store.recent(limit: 10).memories.map(\.id) == [m.id])
    }

    /// The regression guard for the update-path bug: `supersedes` on `update`
    /// used to be silently dropped. This asserts it now sets, keeps-on-omit,
    /// and clears-on-empty — the same omit-vs-replace contract as tags.
    @Test func updateSetsKeepsAndClearsSupersessionEdges() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try await store.add(content: "A", type: .note, actorKind: .cli, actorID: "user")
        let b = try await store.add(content: "B", type: .note, actorKind: .cli, actorID: "user")
        let c = try await store.add(content: "C", type: .note, actorKind: .cli, actorID: "user")

        // All three live to start.
        #expect(Set(try await store.recent(limit: 10).memories.map(\.id)) == [a.id, b.id, c.id])

        // SET: C supersedes A and B (previously a no-op).
        _ = try await store.update(id: c.id, content: "C replaces A and B", type: .note,
                                   supersedes: [a.id, b.id], actorKind: .cli, actorID: "user")
        #expect(try await store.recent(limit: 10).memories.map(\.id) == [c.id])
        #expect(Set(try await store.get(id: c.id)?.supersedes ?? []) == [a.id, b.id])

        // KEEP: omitting supersedes on a later edit leaves the edges intact.
        _ = try await store.update(id: c.id, content: "C v2", type: .note,
                                   actorKind: .cli, actorID: "user")
        #expect(try await store.recent(limit: 10).memories.map(\.id) == [c.id])
        #expect(Set(try await store.get(id: c.id)?.supersedes ?? []) == [a.id, b.id])

        // CLEAR: an explicit empty array drops the edges — A and B go live again.
        _ = try await store.update(id: c.id, content: "C v3", type: .note,
                                   supersedes: [], actorKind: .cli, actorID: "user")
        #expect(Set(try await store.recent(limit: 10).memories.map(\.id)) == [a.id, b.id, c.id])
        #expect((try await store.get(id: c.id)?.supersedes ?? []).isEmpty)
    }

    @Test func compactResultsCarryEdgesButNoBody() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let old = try await store.add(content: "superseded body", type: .note, actorKind: .cli, actorID: "user")
        let new = try await store.add(content: "current body", type: .note,
                                      headline: "Current headline", supersedes: [old.id],
                                      actorKind: .cli, actorID: "user")

        let recent = try #require(try await store.recent(limit: 10).memories.first)
        #expect(recent.id == new.id)
        #expect(recent.content == "")               // compact index omits the body
        #expect(recent.headline == "Current headline") // but keeps the index fields
        #expect(recent.supersedes == [old.id])      // and the edges
    }
}
