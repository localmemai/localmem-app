import Foundation
import Testing
import ArgumentParser
@testable import LocalmemCore
@testable import localmem

/// Both `delete` and `show` share the same id-or-prefix resolution: try the
/// argument as a full UUID first, then fall back to a case-insensitive prefix
/// lookup, surfacing the "no match" and "ambiguous prefix" errors as
/// `ValidationError`s. The two commands carry identical resolve helpers, so we
/// exercise both against the same in-memory store fixtures to lock the
/// branches down.
@Suite("Command resolve(idOrPrefix:store:)")
struct CommandResolveTests {

    private static func makeStore() throws -> (MemoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        return (try MemoryStore(databaseURL: url), url)
    }

    // MARK: - DeleteCommand

    @Test("DeleteCommand.resolve returns the memory for a valid, present UUID")
    func deleteResolvesFullUUID() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(content: "x", type: .note, actorKind: .cli, actorID: "user")
        let cmd = try DeleteCommand.parse([added.id.uuidString])
        let resolved = try await cmd.resolve(idOrPrefix: added.id.uuidString, store: store)
        #expect(resolved.id == added.id)
    }

    @Test("DeleteCommand.resolve handles a syntactically valid UUID that doesn't exist")
    func deleteResolvesAbsentUUIDViaPrefixPath() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // UUID parses fine but isn't in the store — falls through to the
        // prefix lookup, which returns nothing → ValidationError.
        let absent = UUID().uuidString
        let cmd = try DeleteCommand.parse([absent])
        await #expect(throws: ValidationError.self) {
            _ = try await cmd.resolve(idOrPrefix: absent, store: store)
        }
    }

    @Test("DeleteCommand.resolve returns the unique match for an unambiguous prefix")
    func deleteResolvesUniquePrefix() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(content: "x", type: .note, actorKind: .cli, actorID: "user")
        let prefix = String(added.id.uuidString.prefix(8))
        let cmd = try DeleteCommand.parse([prefix])
        let resolved = try await cmd.resolve(idOrPrefix: prefix, store: store)
        #expect(resolved.id == added.id)
    }

    @Test("DeleteCommand.resolve throws ValidationError when no memory matches the prefix")
    func deleteThrowsOnNoMatch() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let cmd = try DeleteCommand.parse(["zzz"])
        await #expect(throws: ValidationError.self) {
            _ = try await cmd.resolve(idOrPrefix: "zzz", store: store)
        }
    }

    @Test("DeleteCommand.resolve throws ValidationError when an empty prefix matches multiple memories")
    func deleteThrowsOnAmbiguous() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "a", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "b", type: .note, actorKind: .cli, actorID: "user")

        // Empty prefix expands to "%" in MemoryStore.findIDs, so it matches
        // both memories and the resolver must reject the input as ambiguous.
        let cmd = try DeleteCommand.parse([""])
        await #expect(throws: ValidationError.self) {
            _ = try await cmd.resolve(idOrPrefix: "", store: store)
        }
    }

    // MARK: - ShowCommand

    @Test("ShowCommand.resolve returns the memory for a valid, present UUID")
    func showResolvesFullUUID() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(content: "x", type: .note, actorKind: .cli, actorID: "user")
        let cmd = try ShowCommand.parse([added.id.uuidString])
        let resolved = try await cmd.resolve(idOrPrefix: added.id.uuidString, store: store)
        #expect(resolved.id == added.id)
    }

    @Test("ShowCommand.resolve returns the unique match for an unambiguous prefix")
    func showResolvesUniquePrefix() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try await store.add(content: "x", type: .note, actorKind: .cli, actorID: "user")
        let prefix = String(added.id.uuidString.prefix(8))
        let cmd = try ShowCommand.parse([prefix])
        let resolved = try await cmd.resolve(idOrPrefix: prefix, store: store)
        #expect(resolved.id == added.id)
    }

    @Test("ShowCommand.resolve throws ValidationError when no memory matches the prefix")
    func showThrowsOnNoMatch() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let cmd = try ShowCommand.parse(["zzz"])
        await #expect(throws: ValidationError.self) {
            _ = try await cmd.resolve(idOrPrefix: "zzz", store: store)
        }
    }

    @Test("ShowCommand.resolve throws ValidationError when the prefix matches multiple memories")
    func showThrowsOnAmbiguous() async throws {
        let (store, url) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "a", type: .note, actorKind: .cli, actorID: "user")
        _ = try await store.add(content: "b", type: .note, actorKind: .cli, actorID: "user")

        let cmd = try ShowCommand.parse([""])
        await #expect(throws: ValidationError.self) {
            _ = try await cmd.resolve(idOrPrefix: "", store: store)
        }
    }
}
