import Foundation
import LocalMemCore
import MCP

struct ToolRegistry: Sendable {
    let store: MemoryStore

    // MARK: - Descriptors

    var toolDescriptors: [Tool] {
        [storeTool, searchTool, recentTool]
    }

    private var storeTool: Tool {
        Tool(
            name: "memory_store",
            description: "Persist a new memory in LocalMem.",
            inputSchema: [
                "type": "object",
                "required": ["content"],
                "properties": [
                    "content": [
                        "type": "string",
                        "description": "The memory content.",
                    ],
                    "title": [
                        "type": "string",
                        "description": "Optional short title.",
                    ],
                    "type": [
                        "type": "string",
                        "enum": .array(MemoryType.allCases.map { .string($0.rawValue) }),
                        "default": "note",
                    ],
                    "tags": [
                        "type": "array",
                        "items": ["type": "string"],
                        "default": .array([]),
                    ],
                ],
            ]
        )
    }

    private var searchTool: Tool {
        Tool(
            name: "memory_search",
            description: "Full-text search over stored memories.",
            inputSchema: [
                "type": "object",
                "required": ["query"],
                "properties": [
                    "query": ["type": "string"],
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 50,
                        "default": 20,
                    ],
                ],
            ]
        )
    }

    private var recentTool: Tool {
        Tool(
            name: "memory_recent",
            description: "Most recently created memories, newest first.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 50,
                        "default": 20,
                    ],
                ],
            ]
        )
    }

    // MARK: - Dispatch

    func call(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        let args = arguments ?? [:]
        switch name {
        case "memory_store":  return try await handleStore(args)
        case "memory_search": return try await handleSearch(args)
        case "memory_recent": return try await handleRecent(args)
        default:              throw MCPError.methodNotFound("Unknown tool: \(name)")
        }
    }

    private func handleStore(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let content = args["content"]?.stringValue, !content.isEmpty else {
            throw MCPError.invalidParams("`content` is required and must be non-empty.")
        }
        let title = args["title"]?.stringValue

        let typeRaw = args["type"]?.stringValue ?? "note"
        guard let type = MemoryType(rawValue: typeRaw) else {
            throw MCPError.invalidParams("Unknown memory type: \(typeRaw)")
        }

        let tags = args["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        let memory = try await store.add(
            content: content,
            type: type,
            title: title,
            tags: tags,
            source: .claude
        )
        return .init(content: [.plainText("{\"id\":\"\(memory.id.uuidString)\"}")])
    }

    private func handleSearch(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let query = args["query"]?.stringValue else {
            throw MCPError.invalidParams("`query` is required.")
        }
        let limit = args["limit"]?.intValue ?? 20
        let memories = try await store.search(query: query, limit: limit)
        return .init(content: [.plainText(try memories.toJSONString())])
    }

    private func handleRecent(_ args: [String: Value]) async throws -> CallTool.Result {
        let limit = args["limit"]?.intValue ?? 20
        let memories = try await store.recent(limit: limit)
        return .init(content: [.plainText(try memories.toJSONString())])
    }
}

// MARK: - Ergonomic helpers

private extension Tool.Content {
    /// Shortcut for the verbose `.text(text:annotations:_meta:)` canonical form.
    static func plainText(_ s: String) -> Tool.Content {
        .text(text: s, annotations: nil, _meta: nil)
    }
}

private extension Array where Element == Memory {
    func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
