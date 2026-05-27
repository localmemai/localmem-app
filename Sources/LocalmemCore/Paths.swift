import Foundation

public enum Paths {
    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Localmem", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func databaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("memory.sqlite3")
    }
}
