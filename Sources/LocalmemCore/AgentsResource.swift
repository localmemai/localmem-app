import Foundation

public enum AgentsResourceError: Error, Sendable {
    case bundleResourceMissing
}

/// Accessor for the bundled `AGENTS.md` shipped with the LocalmemCore module.
/// The file is copied verbatim to `~/.localmem/AGENTS.md` by `InstructionsInstaller`.
public enum AgentsResource {
    public static func read() throws -> String {
        guard let url = Bundle.module.url(forResource: "AGENTS", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { throw AgentsResourceError.bundleResourceMissing }
        return raw
    }
}
