import Foundation
import Testing
import ArgumentParser
@testable import LocalmemCore
@testable import localmem

/// Argument validation that runs *before* a command opens the database.
/// Every branch here rejects bad input without touching the user's vault —
/// which is also what makes it testable, since `MemoryStore()` would resolve
/// the real Application Support path.
@Suite("Command argument validation")
struct CommandValidationTests {

    private static func makeStore() throws -> (MemoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        return (try MemoryStore(databaseURL: url), url)
    }

    // MARK: - FolderCommand.Delete

    @Test("folder delete rejects a non-UUID argument before opening the store")
    func folderDeleteRejectsBadUUID() async throws {
        let cmd = try FolderCommand.Delete.parse(["not-a-uuid"])
        await #expect(throws: ValidationError.self) {
            try await cmd.run()
        }
    }

    // MARK: - FolderCommand.Merge

    @Test("folder merge rejects an id list containing no valid UUIDs")
    func folderMergeRejectsNoValidUUIDs() async throws {
        let cmd = try FolderCommand.Merge.parse(["nope, still-nope", "Target"])
        await #expect(throws: ValidationError.self) {
            try await cmd.run()
        }
    }

    @Test("folder merge parses a comma-separated list with surrounding whitespace")
    func folderMergeParsesIDList() throws {
        let first = UUID(), second = UUID()
        let cmd = try FolderCommand.Merge.parse([
            " \(first.uuidString) ,\(second.uuidString)", "Target",
        ])
        #expect(cmd.ids.contains(first.uuidString))
        #expect(cmd.targetName == "Target")
    }

    // MARK: - AgentCommand.SetStatus

    @Test("agents set --all resolves to the all-access status")
    func agentSetAll() throws {
        let cmd = try AgentCommand.SetStatus.parse(["claude-code", "--all"])
        #expect(try cmd.resolvedStatus() == .all)
    }

    @Test("agents set --non-sensitive-only resolves to the restricted status")
    func agentSetNonSensitive() throws {
        let cmd = try AgentCommand.SetStatus.parse(["claude-code", "--non-sensitive-only"])
        #expect(try cmd.resolvedStatus() == .nonSensitiveOnly)
    }

    @Test("agents set with neither flag is a usage error, not a silent default")
    func agentSetRequiresAFlag() throws {
        let cmd = try AgentCommand.SetStatus.parse(["claude-code"])
        #expect(throws: ValidationError.self) {
            _ = try cmd.resolvedStatus()
        }
    }

    /// Both flags is nonsense input; whichever wins, it must not fall through
    /// to the error branch and must not widen access unexpectedly.
    @Test("agents set with both flags resolves deterministically to --all")
    func agentSetBothFlags() throws {
        let cmd = try AgentCommand.SetStatus.parse(["claude-code", "--all", "--non-sensitive-only"])
        #expect(try cmd.resolvedStatus() == .all)
    }

    // MARK: - AddCommand.resolveFolderID

    @Test("add without --folder files into Inbox by returning no folder id")
    func addResolvesNoFolder() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let cmd = try AddCommand.parse(["some content"])
        #expect(try await cmd.resolveFolderID(store) == nil)
    }

    @Test("add --folder accepts a UUID verbatim without a name lookup")
    func addResolvesUUIDFolder() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let id = UUID()
        let cmd = try AddCommand.parse(["some content", "--folder", id.uuidString])
        #expect(try await cmd.resolveFolderID(store) == id)
    }

    @Test("add --folder matches an existing folder name case-insensitively")
    func addResolvesFolderNameCaseInsensitively() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let folder = try await store.createFolder(name: "Recipes", kind: .manual,
                                                  projectRoot: nil, isSensitive: false)
        let cmd = try AddCommand.parse(["some content", "--folder", "rEcIpEs"])
        #expect(try await cmd.resolveFolderID(store) == folder.id)
    }

    @Test("add --folder with an unknown name errors and lists the folders that exist")
    func addRejectsUnknownFolderName() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.createFolder(name: "Recipes", kind: .manual,
                                         projectRoot: nil, isSensitive: false)
        let cmd = try AddCommand.parse(["some content", "--folder", "Nowhere"])
        do {
            _ = try await cmd.resolveFolderID(store)
            Issue.record("expected a ValidationError for the unknown folder")
        } catch let error as ValidationError {
            let message = String(describing: error)
            #expect(message.contains("Nowhere"))
            #expect(message.contains("Recipes"))
        }
    }

    @Test("an empty --folder value falls back to Inbox rather than erroring")
    func addTreatsEmptyFolderAsUnset() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let cmd = try AddCommand.parse(["some content", "--folder", ""])
        #expect(try await cmd.resolveFolderID(store) == nil)
    }

    @Test("--type parses each MemoryType and defaults to note")
    func addParsesMemoryType() throws {
        #expect(try AddCommand.parse(["x"]).type == .note)
        #expect(try AddCommand.parse(["x", "--type", "preference"]).type == .preference)
        #expect(try AddCommand.parse(["x", "--type", "decision"]).type == .decision)
        #expect(throws: (any Error).self) {
            _ = try AddCommand.parse(["x", "--type", "nonsense"])
        }
    }

    @Test("repeating --tag accumulates tags instead of replacing them")
    func addAccumulatesTags() throws {
        let cmd = try AddCommand.parse(["x", "--tag", "coffee", "--tag", "morning_routine"])
        #expect(cmd.tags == ["coffee", "morning_routine"])
    }

    // MARK: - SupersedeCommand.resolve

    @Test("supersede resolves both a full UUID and an unambiguous prefix")
    func supersedeResolvesIDs() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let old = try await store.add(content: "old", type: .note, actorKind: .cli, actorID: "user")
        let new = try await store.add(content: "new", type: .note, actorKind: .cli, actorID: "user")
        let cmd = try SupersedeCommand.parse([old.id.uuidString, "--with", new.id.uuidString])

        #expect(try await cmd.resolve(idOrPrefix: old.id.uuidString, store: store) == old.id)
        #expect(try await cmd.resolve(idOrPrefix: String(new.id.uuidString.prefix(8)), store: store) == new.id)
    }

    @Test("supersede errors on a prefix that matches nothing")
    func supersedeRejectsUnknownPrefix() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let cmd = try SupersedeCommand.parse(["zzzzzzzz", "--with", "zzzzzzzz"])
        await #expect(throws: ValidationError.self) {
            _ = try await cmd.resolve(idOrPrefix: "zzzzzzzz", store: store)
        }
    }

    @Test("supersede errors on a prefix that matches more than one memory")
    func supersedeRejectsAmbiguousPrefix() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // Seed until two ids share a first character, then use it as the
        // ambiguous prefix.
        var seen: [Character: Int] = [:]
        var ambiguous: Character?
        for _ in 0..<64 where ambiguous == nil {
            let memory = try await store.add(content: "m", type: .note, actorKind: .cli, actorID: "user")
            let first = try #require(memory.id.uuidString.lowercased().first)
            seen[first, default: 0] += 1
            if seen[first] == 2 { ambiguous = first }
        }
        let prefix = try #require(ambiguous, "expected two ids sharing a leading character")

        let cmd = try SupersedeCommand.parse([String(prefix), "--with", String(prefix)])
        await #expect(throws: ValidationError.self) {
            _ = try await cmd.resolve(idOrPrefix: String(prefix), store: store)
        }
    }
}
