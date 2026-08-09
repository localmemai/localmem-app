import Foundation

public enum Paths {
    /// Overrides the vault location for every binary in the package.
    ///
    /// Exists so the demo vault used for marketing screenshots
    /// (`scripts/seed-demo-vault.sh`) can be built and photographed without
    /// touching — or publishing — the developer's real memories. That was the
    /// standing reason screenshots went stale: regenerating them meant curating
    /// your own vault by hand first.
    ///
    /// Also useful for manual QA and for reproducing a bug on a known state.
    /// Not a supported end-user setting; nothing in the UI surfaces it.
    public static let vaultDirectoryOverrideKey = "LOCALMEM_VAULT_DIR"

    public static func applicationSupportDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment[vaultDirectoryOverrideKey],
           !override.isEmpty {
            let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                          isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
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
        try applicationSupportDirectory().appendingPathComponent("localmem.sqlite3")
    }
}
