import Foundation
import Testing
@testable import LocalmemCore

@Suite("Paths")
struct PathsTests {
    @Test("applicationSupportDirectory returns a created Localmem subdirectory")
    func appSupportDirectoryIsCreatedLocalmem() throws {
        let url = try Paths.applicationSupportDirectory()
        #expect(url.lastPathComponent == "Localmem")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("databaseURL is the app-support dir plus localmem.sqlite3")
    func databaseURLIsSiblingOfAppSupport() throws {
        let dir = try Paths.applicationSupportDirectory()
        let db = try Paths.databaseURL()
        #expect(db.deletingLastPathComponent().path == dir.path)
        #expect(db.lastPathComponent == "localmem.sqlite3")
    }
}
