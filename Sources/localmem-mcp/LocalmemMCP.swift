import Foundation
import LocalmemCore
import MCP

@main
struct LocalmemMCP {
    static func main() async throws {
        let database = try LocalmemDatabase()
        let store = MemoryStore(database: database)
        let activityStore = ActivityStore(database: database)
        let identity = MCPClientIdentity()
        let registry = ToolRegistry(store: store, activityStore: activityStore, identity: identity)

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
        try await server.start(transport: transport) { clientInfo, _ in
            await identity.set(clientInfo.name)
            Log.notice(.mcp, "MCP client connected", ["actor_id": clientInfo.name])
        }
        Log.notice(.mcp, "Localmem MCP server ready.")
        await server.waitUntilCompleted()
    }
}
