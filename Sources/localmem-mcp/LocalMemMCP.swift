import Foundation
import LocalMemCore
import MCP

@main
struct LocalMemMCP {
    static func main() async throws {
        let store = try MemoryStore()
        let registry = ToolRegistry(store: store)

        let server = Server(
            name: "localmem",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: registry.toolDescriptors)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await registry.call(name: params.name, arguments: params.arguments)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        log("LocalMem MCP server ready.")
        await server.waitUntilCompleted()
    }

    /// stdout is the MCP transport — diagnostics must go to stderr only.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[localmem-mcp] \(message)\n".utf8))
    }
}
