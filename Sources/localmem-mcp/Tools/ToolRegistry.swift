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
        [storeTool, searchTool, recentTool, updateTool]
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

            FORMAT — every call MUST follow this shape. Do not invent variants.

            • content (required): one fact, third person, present tense, full
              sentence with terminal punctuation. The subject is implicit — NEVER
              write "User likes…" or "The user…". Write what is true.
                Good:  "Prefers flat white with oat milk."
                Good:  "Backend engineer with ten years of Go; new to React."
                Bad:   "User loves coffee."  "Likes coffee"  "Flat white. Oat milk."
              One fact per call — split multi-fact statements into multiple calls.

            • title (optional but strongly preferred): a 3–6 word noun phrase in
              sentence case. Names the fact, does not state it. No trailing
              period. No "User" prefix.
                Good:  "Coffee preference"  "Backend role"  "Linear INGEST tracker"
                Bad:   "User Preference: Coding"  "User likes coffee."  "coffee"

            • type (optional, default "note"): exactly one of
              `preference` · `decision` · `fact` · `project` · `note`.
                preference — how the user wants to work or be treated.
                decision   — a choice that should outlive the conversation.
                fact       — biographical or contextual fact (role, location, expertise).
                project    — an ongoing initiative or work context.
                note       — fallback; use sparingly, hurts recall.

            • tags (optional): 1–3 lowercase tags, snake_case for multi-word.
              ALWAYS singular ("preference", not "preferences"). Do NOT tag with
              "user" or "user_profile" — every row is about the user. Reuse
              existing tags rather than invent synonyms; call memory_search first
              if unsure.
                Good:  ["coffee", "preference"]  ["role", "fact"]  ["morning_routine"]
                Bad:   ["preferences"]  ["User Preference"]  ["user_profile"]

            CANONICAL EXAMPLE:
            User: "I'm a Go engineer, mostly backend, allergic to frontend work."
            Three separate calls — one fact per memory:
            → memory_store(title: "Backend role",
                           content: "Backend engineer focused on Go.",
                           type: "fact", tags: ["role"])
            → memory_store(title: "Frontend aversion",
                           content: "Prefers to avoid frontend work.",
                           type: "preference", tags: ["preference", "workflow"])
            """,
            inputSchema: [
                "type": "object",
                "required": ["content"],
                "properties": [
                    "content": [
                        "type": "string",
                        "description": "One fact, third person, present tense, full sentence with terminal punctuation. Subject is implicit — do not write 'User'.",
                    ],
                    "title": [
                        "type": "string",
                        "description": "3-6 word noun phrase, sentence case, no trailing period, no 'User' prefix.",
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

            VISIBILITY:
            • Results omit memories whose per-memory access list excludes this MCP client.

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

            VISIBILITY:
            • Results omit memories whose per-memory access list excludes this MCP client.

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

    private var updateTool: Tool {
        Tool(
            name: "memory_update",
            description: """
            Replace an existing memory's fields. Partial — pass only the fields
            you want to change; everything you omit keeps its current value.

            DESTRUCTIVE. The client should prompt the user before every call —
            this tool is deliberately NOT in Localmem's pre-authorized list.

            USE WHEN:
            • The user corrects a stored fact ("actually, I prefer cortados now").
            • A stored decision changes ("we're moving the API gateway to Envoy").
            • A reference URL or person's role becomes stale.

            DO NOT USE WHEN:
            • The change is *additive* (a separate fact, not a correction) — call
              `memory_store` instead, so both versions are preserved.
            • You want to retag a memory just to make it discoverable — instead,
              `memory_update` it with the broader tag set.

            ARGS:
            • id (required): full UUID of the memory to update. Call
              `memory_search` or `memory_recent` first to find it.
            • title (optional): new title. Omit to keep the existing one.
            • content (optional): new content. Omit to keep existing.
            • type (optional): one of `preference`, `decision`, `fact`,
              `project`, `note`. Omit to keep existing.
            • tags (optional): full replacement of the tag list. Omit to keep
              the existing tags; pass `[]` to clear them.

            EXAMPLE:
            User: "Actually I drink oat-milk cortados now, not flat whites."
            → memory_search(query: "coffee")           # find the memory id
            → memory_update(id: "8AF5...", content: "Loves oat-milk cortados.")
            """,
            inputSchema: [
                "type": "object",
                "required": ["id"],
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "UUID of the memory to update.",
                    ],
                    "title": [
                        "type": "string",
                        "description": "Replacement title. Omit to keep existing.",
                    ],
                    "content": [
                        "type": "string",
                        "description": "Replacement content, third person, present tense, terminal punctuation.",
                    ],
                    "type": [
                        "type": "string",
                        "enum": .array(MemoryType.allCases.map { .string($0.rawValue) }),
                    ],
                    "tags": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Replacement tag list. Pass [] to clear tags.",
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
        case "memory_update": return try await handleUpdate(args)
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
        let actorID = await identity.name
        let memories = try await store.search(query: query, limit: limit, requestingAgent: actorID)
        do {
            try await activityStore.add(Activity(
                actorKind: .mcp,
                actorID: actorID,
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
        let actorID = await identity.name
        let memories = try await store.recent(limit: limit, requestingAgent: actorID)
        do {
            try await activityStore.add(Activity(
                actorKind: .mcp,
                actorID: actorID,
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

    /// Partial-update handler — agents pass only the fields they want to
    /// change, and the server merges those onto the current row. Activity
    /// row is written inside `store.update`'s transaction.
    private func handleUpdate(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let idString = args["id"]?.stringValue, !idString.isEmpty else {
            throw MCPError.invalidParams("`id` is required.")
        }
        guard let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a UUID string.")
        }
        let actorID = await identity.name
        guard let existing = try await store.get(id: id, requestingAgent: actorID) else {
            throw MCPError.invalidParams("No memory with id \(idString).")
        }

        // Merge: each field defaults to the existing memory's value when the
        // caller doesn't specify it. `tags` distinguishes "omitted" (keep) from
        // "explicit empty array" (clear) via the arrayValue presence check.
        let content = args["content"]?.stringValue ?? existing.content
        guard content.utf8.count <= Self.maxContentBytes else {
            throw MCPError.invalidParams(
                "`content` is \(content.utf8.count) bytes; max is \(Self.maxContentBytes)."
            )
        }

        let title: String?
        if let raw = args["title"]?.stringValue {
            title = raw.isEmpty ? nil : raw
        } else {
            title = existing.title
        }

        let type: MemoryType
        if let typeRaw = args["type"]?.stringValue {
            guard let parsed = MemoryType(rawValue: typeRaw) else {
                throw MCPError.invalidParams("Unknown memory type: \(typeRaw)")
            }
            type = parsed
        } else {
            type = existing.type
        }

        let tags: [String]
        if let rawTags = args["tags"]?.arrayValue {
            tags = Array(
                rawTags.compactMap { $0.stringValue }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.count <= Self.maxTagLength }
                    .prefix(Self.maxTagCount)
            )
        } else {
            tags = existing.tags
        }

        let updated = try await store.update(
            id: id,
            content: content,
            type: type,
            title: title,
            tags: tags,
            actorKind: .mcp,
            actorID: actorID
        )
        return .init(content: [.plainText("{\"id\":\"\(updated.id.uuidString)\"}")])
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
        let data = try encoder.encode(map(MCPMemory.init(memory:)))
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

private struct MCPMemory: Encodable {
    let id: UUID
    let type: MemoryType
    let title: String?
    let content: String
    let tags: [String]
    let source: String?
    let createdAt: Date
    let updatedAt: Date

    init(memory: Memory) {
        id = memory.id
        type = memory.type
        title = memory.title
        content = memory.content
        tags = memory.tags
        source = memory.source
        createdAt = memory.createdAt
        updatedAt = memory.updatedAt
    }
}
