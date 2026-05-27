import Foundation

enum BinaryLocator {
    /// Returns the absolute path of the localmem-mcp binary that should be
    /// registered with MCP clients. Resolves as a sibling of the running
    /// localmem executable, so it works in both .build/release/ and /usr/local/bin/.
    static func mcpServerPath() throws -> String {
        guard let executablePath = Bundle.main.executablePath else {
            throw SetupError.cannotLocateBinary(reason: "Bundle.main.executablePath is nil")
        }
        let mcpURL = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent("localmem-mcp")

        guard FileManager.default.isExecutableFile(atPath: mcpURL.path) else {
            throw SetupError.cannotLocateBinary(
                reason: "no executable at \(mcpURL.path) (build with `swift build -c release` first)"
            )
        }
        return mcpURL.path
    }
}

enum SetupError: Error, CustomStringConvertible {
    case cannotLocateBinary(reason: String)
    case cliNotSupported(client: String)

    var description: String {
        switch self {
        case .cannotLocateBinary(let reason):
            return "Cannot locate localmem-mcp binary: \(reason)"
        case .cliNotSupported(let client):
            return "\(client) has no CLI-based registration path"
        }
    }
}
