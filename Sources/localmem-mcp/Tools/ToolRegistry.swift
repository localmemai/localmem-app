import Foundation
import LocalmemCore
import MCP

struct ToolRegistry: Sendable {
    let store: MemoryStore
    let activityStore: ActivityStore
    let identity: MCPClientIdentity

    init(store: MemoryStore, activityStore: ActivityStore, identity: MCPClientIdentity) {
        self.store = store
        self.activityStore = activityStore
        self.identity = identity
    }

    // MARK: - Descriptors

    var toolDescriptors: [Tool] {
        [storeTool, searchTool, recentTool]
    }

    private var storeTool: Tool {
        Tool(
            name: "memory_store",
            description: """
            Persist a single fact, preference, decision, or pointer in Localmem so it
            outlives the current conversation and is available in every future session
            with this user, across every project.

            USE WHEN:
            • The user states a preference about themselves, their workflow, or their tools.
            • The user corrects you, or explicitly validates a non-obvious approach you took.
            • A decision is made (product, architectural, personal) that future sessions
              should respect without being re-derived.
            • The user names an external resource (dashboard, ticket tracker, doc URL,
              Slack channel) you will need to recall later.

            DO NOT USE FOR:
            • Code patterns, file paths, or conventions that can be re-read from the
              project state — that's what reading files is for.
            • Information already captured by `git log` / `git blame`.
            • Ephemeral state (current TODO list, in-flight work, scratchpad).
            • Anything already documented in this project's CLAUDE.md / AGENTS.md —
              project files take precedence and are versioned.

            ARGS:
            • content (required): the memory text, in the user's own words where possible.
              One fact per call — split multi-fact statements into multiple calls.
            • type (optional): one of `note` (default), `preference`, `decision`, `task`,
              `reference`. Choose what best matches the content; it shapes how recall
              surfaces the memory.
            • title (optional): a 3-6 word handle. Helps the user when they later run
              `localmem list` from the CLI.
            • tags (optional): array of short lowercase keywords. Use them when you can
              anticipate future searches ("coffee", "auth", "deploy").

            EXAMPLE:
            User: "I'm a Go engineer, mostly backend, allergic to frontend work."
            → memory_store(content: "Go engineer, backend-focused, prefers to avoid \
            frontend work", type: "preference", tags: ["role", "preferences"])
            """,
            inputSchema: [
                "type": "object",
                "required": ["content"],
                "properties": [
                    "content": [
                        "type": "string",
                        "description": "The memory content, in the user's own words where possible.",
                    ],
                    "title": [
                        "type": "string",
                        "description": "Optional 3-6 word handle for CLI listings.",
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
            description: """
            Full-text search over Localmem. Returns matches newest-first. Cheap — call
            it whenever you need context, do not try to "remember" from prior turns.

            USE BEFORE ANSWERING:
            • Any question that depends on prior conversations ("pick up where we left off",
              "what did we decide about X", "remind me…").
            • Any request that touches the user's stated preferences (style, tooling,
              workflow) where guessing wrong is costly.
            • Any reference to an external system the user has mentioned before.

            QUERY STYLE:
            • Use the keyword you'd expect in the stored content, NOT a full-sentence
              question. "auth refactor" beats "what were we doing with auth?"
            • If the first query returns nothing, try again with different terms —
              memories are stored in the user's own phrasing, which may not match yours.
            • Search is a substring match over content + title + tags.

            ARGS:
            • query (required): the search string.
            • limit (optional, default 20, max 50): cap on result count.

            EXAMPLE:
            User: "Pick up where we left off on the auth refactor."
            → memory_search(query: "auth refactor")
            """,
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
            description: """
            Returns the N most recently created memories, newest first. The
            no-keyword companion to `memory_search`: use it when you need ambient
            context and don't yet have a concrete search term.

            USE WHEN:
            • The user opens a session and references "what we talked about last time"
              or "where we left off" without naming a specific topic.
            • You're starting a turn and want a quick situational refresh.
            • The user asks open-ended questions about themselves: "what do you
              remember about me?", "what do you know about my preferences?"

            PREFER `memory_search` WHEN YOU HAVE A KEYWORD. `memory_recent` is the
            fallback for the no-keyword case — calling it speculatively wastes
            context window with memories the agent won't use.

            ARGS:
            • limit (optional, default 20, max 50): how many to return.

            EXAMPLE:
            User: "Morning! What's on the docket?"
            → memory_recent(limit: 10)
            """,
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

    // MARK: - Limits
    // Must match the bounds advertised in the input schemas above. JSON-Schema
    // bounds are advisory; the server has to enforce them itself.

    private static let defaultLimit = 20
    private static let maxLimit = 50
    private static let maxContentBytes = 64_000
    private static let maxTagCount = 16
    private static let maxTagLength = 64

    private static func clampLimit(_ raw: Int?) -> Int {
        max(1, min(maxLimit, raw ?? defaultLimit))
    }

    // MARK: - Dispatch

    func call(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        let args = arguments ?? [:]
        switch name {
        // memory_store's audit row is written inside store.add's transaction.
        case "memory_store":  return try await handleStore(args)
        case "memory_search": return try await handleSearch(args)
        case "memory_recent": return try await handleRecent(args)
        default:              throw MCPError.methodNotFound("Unknown tool: \(name)")
        }
    }

    // MARK: - Handlers

    private func handleStore(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let content = args["content"]?.stringValue, !content.isEmpty else {
            throw MCPError.invalidParams("`content` is required and must be non-empty.")
        }
        guard content.utf8.count <= Self.maxContentBytes else {
            throw MCPError.invalidParams(
                "`content` is \(content.utf8.count) bytes; max is \(Self.maxContentBytes). Split into multiple memories."
            )
        }
        let title = args["title"]?.stringValue

        let typeRaw = args["type"]?.stringValue ?? "note"
        guard let type = MemoryType(rawValue: typeRaw) else {
            throw MCPError.invalidParams("Unknown memory type: \(typeRaw)")
        }

        let tags = Array(
            (args["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= Self.maxTagLength }
                .prefix(Self.maxTagCount)
        )

        let memory = try await store.add(
            content: content,
            type: type,
            title: title,
            tags: tags,
            actorKind: .mcp,
            actorID: await identity.name
        )
        return .init(content: [.plainText("{\"id\":\"\(memory.id.uuidString)\"}")])
    }

    private func handleSearch(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let query = args["query"]?.stringValue else {
            throw MCPError.invalidParams("`query` is required.")
        }
        let limit = Self.clampLimit(args["limit"]?.intValue)
        let memories = try await store.search(query: query, limit: limit)
        do {
            try await activityStore.add(Activity(
                actorKind: .mcp,
                actorID: await identity.name,
                operation: "memory_search",
                query: query,
                resultCount: memories.count
            ))
        } catch {
            Log.error(.mcp, "Failed to write activity row", [
                "operation": "memory_search",
                "error": String(describing: error),
            ])
        }
        return .init(content: [.plainText(try memories.toJSONString())])
    }

    private func handleRecent(_ args: [String: Value]) async throws -> CallTool.Result {
        let limit = Self.clampLimit(args["limit"]?.intValue)
        let memories = try await store.recent(limit: limit)
        do {
            try await activityStore.add(Activity(
                actorKind: .mcp,
                actorID: await identity.name,
                operation: "memory_recent",
                resultCount: memories.count
            ))
        } catch {
            Log.error(.mcp, "Failed to write activity row", [
                "operation": "memory_recent",
                "error": String(describing: error),
            ])
        }
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
