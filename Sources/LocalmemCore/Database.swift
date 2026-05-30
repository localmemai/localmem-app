import Foundation
import GRDB

public final class LocalmemDatabase: @unchecked Sendable {
    private let queue: DatabaseQueue

    public convenience init() throws {
        try self.init(url: Paths.databaseURL())
    }

    public init(url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }
        self.queue = try DatabaseQueue(path: url.path, configuration: config)
        try Migrations.migrator.migrate(queue)
    }

    func read<T: Sendable>(_ body: @Sendable @escaping (GRDB.Database) throws -> T) async throws -> T {
        try await queue.read(body)
    }

    func write<T: Sendable>(_ body: @Sendable @escaping (GRDB.Database) throws -> T) async throws -> T {
        try await queue.write(body)
    }
}
