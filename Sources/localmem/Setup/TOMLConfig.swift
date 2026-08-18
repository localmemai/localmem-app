import Foundation
import TOMLKit

enum TOMLConfig {
    /// Reads a TOML document from disk (empty if missing), applies `transform`, writes atomically.
    /// Returns `true` if the file content actually changed.
    /// TOMLTable is a reference type — the transform mutates it in place.
    @discardableResult
    static func update(at url: URL, transform: (TOMLTable) -> Void) throws -> Bool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let table: TOMLTable
        let originalText: String?
        if FileManager.default.fileExists(atPath: url.path) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            originalText = raw
            table = try TOMLTable(string: raw)
        } else {
            originalText = nil
            table = TOMLTable()
        }

        transform(table)
        let nextText = table.convert()

        if originalText == nextText { return false }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        // 0600 on the temp file, which `replaceItemAt` carries across when the
        // destination is new. These configs routinely hold API keys for other
        // MCP servers, so a file Localmem creates from scratch must not land at
        // the default 0644 and become readable by other local accounts. An
        // existing file keeps its own attributes through the replace.
        try nextText.write(to: tempURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: tempURL.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        return true
    }

    /// Read-side helper for status checks. Returns the entry table if present.
    static func readMcpEntry(
        at url: URL,
        mcpServersKey: String = "mcp_servers",
        serverName: String
    ) -> TOMLTable? {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let table = try? TOMLTable(string: raw),
              let servers = table[mcpServersKey]?.table,
              let entry = servers[serverName]?.table
        else { return nil }
        return entry
    }
}
