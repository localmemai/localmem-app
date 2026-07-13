import Foundation

enum JSONConfig {
    /// Reads a JSON object from disk (empty if missing), applies `transform`, writes atomically.
    /// Creates parent directories if needed. Returns `true` if file content changed.
    @discardableResult
    static func update(at url: URL, transform: ([String: Any]) -> [String: Any]) throws -> Bool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var current: [String: Any] = [:]
        let fileExisted = FileManager.default.fileExists(atPath: url.path)
        if fileExisted {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                current = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
        }

        let next = transform(current)
        let nextData = try JSONSerialization.data(
            withJSONObject: next,
            options: [.prettyPrinted, .sortedKeys]
        )

        // Skip rewrite if structurally identical. Re-serialize the already-parsed
        // `current` instead of re-reading the file.
        if fileExisted {
            let currentNormalized = try JSONSerialization.data(
                withJSONObject: current,
                options: [.prettyPrinted, .sortedKeys]
            )
            if currentNormalized == nextData { return false }
        }

        // Atomic write: temp file in the same dir, then replace.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try nextData.write(to: tempURL)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        return true
    }

    /// Read-side helper for status checks. Returns the entry dictionary if present.
    static func readMcpEntry(
        at url: URL,
        mcpServersKey: String = "mcpServers",
        serverName: String
    ) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[mcpServersKey] as? [String: Any],
              let entry = servers[serverName] as? [String: Any]
        else { return nil }
        return entry
    }
}
