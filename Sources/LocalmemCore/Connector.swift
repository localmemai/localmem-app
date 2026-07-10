import Foundation

// MARK: - Limits

/// Guardrails so one huge/pathological file can't hang the app, exhaust memory,
/// flood the store, or run up agent cost. See docs/File_Connector_Design.md.
public enum ConnectorLimits {
    public static let maxFileSizeBytes = 20 * 1024 * 1024        // 20 MB — the PDF guard
    public static let maxTextChars = 1_000_000                    // ~1 MB of text per file
    public static let maxFactsPerFile = 200
    public static let maxFilesPerSource = 5_000
    public static let extractionTimeout: TimeInterval = 180
    public static let supportedExtensions: Set<String> = ["txt", "md", "markdown", "text", "pdf"]
}

// MARK: - Backend

/// Which engine extracts facts. `apple` is the on-device model (private);
/// `agent(id)` delegates to a configured CLI agent (e.g. "claude-code").
public enum ExtractionBackend: Equatable, Sendable {
    case apple
    case agent(String)

    public var storageValue: String {
        switch self {
        case .apple:         return "apple"
        case .agent(let id): return "agent:\(id)"
        }
    }

    public init?(storageValue: String) {
        if storageValue == "apple" {
            self = .apple
        } else if storageValue.hasPrefix("agent:") {
            self = .agent(String(storageValue.dropFirst("agent:".count)))
        } else {
            return nil
        }
    }

    public var isOnDevice: Bool { self == .apple }
}

// MARK: - Source

/// A folder or file the user connected to import memories from.
public struct ImportSource: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case folder, file }
    public enum Status: String, Sendable { case active, disconnected }

    public let id: UUID
    public var name: String
    public var connector: String
    public var kind: Kind
    public var path: String
    public var bookmark: Data?
    public var backend: ExtractionBackend
    public var autoProcess: Bool
    public var status: Status
    public var lastRunAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        connector: String = "files",
        kind: Kind,
        path: String,
        bookmark: Data? = nil,
        backend: ExtractionBackend,
        autoProcess: Bool = true,
        status: Status = .active,
        lastRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.connector = connector
        self.kind = kind
        self.path = path
        self.bookmark = bookmark
        self.backend = backend
        self.autoProcess = autoProcess
        self.status = status
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Per-file processing state, for change detection and the landing page.
public struct SourceFileState: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case pending, processed, partial, skipped, failed }

    public var relPath: String
    public var contentSHA256: String?
    public var modifiedAt: Date?
    public var processedAt: Date?
    public var status: Status
    public var reasonCode: String?
    public var error: String?
    public var factCount: Int

    public var id: String { relPath }

    public init(relPath: String, contentSHA256: String? = nil, modifiedAt: Date? = nil,
                processedAt: Date? = nil, status: Status, reasonCode: String? = nil,
                error: String? = nil, factCount: Int = 0) {
        self.relPath = relPath
        self.contentSHA256 = contentSHA256
        self.modifiedAt = modifiedAt
        self.processedAt = processedAt
        self.status = status
        self.reasonCode = reasonCode
        self.error = error
        self.factCount = factCount
    }
}

/// Aggregate stats shown on a source's landing page.
public struct SourceStats: Sendable, Equatable {
    public var filesProcessed: Int
    public var filesSkipped: Int
    public var filesFailed: Int
    public var factCount: Int
    public var lastProcessed: Date?

    public init(filesProcessed: Int = 0, filesSkipped: Int = 0, filesFailed: Int = 0,
                factCount: Int = 0, lastProcessed: Date? = nil) {
        self.filesProcessed = filesProcessed
        self.filesSkipped = filesSkipped
        self.filesFailed = filesFailed
        self.factCount = factCount
        self.lastProcessed = lastProcessed
    }
}

// MARK: - Extraction

/// One extracted fact — maps 1:1 onto `Memory`.
public struct ExtractedFact: Sendable, Equatable {
    public var title: String
    public var content: String
    public var type: MemoryType
    public var tags: [String]

    public init(title: String, content: String, type: MemoryType, tags: [String]) {
        self.title = title
        self.content = content
        self.type = type
        self.tags = tags
    }
}

public struct ExtractionContext: Sendable {
    public var sourceName: String
    public var relPath: String
    public init(sourceName: String, relPath: String) {
        self.sourceName = sourceName
        self.relPath = relPath
    }
}

public enum ExtractionError: Error, Sendable {
    case unavailable(String)      // backend not usable at all (surface, don't fall back silently)
    case failed(String)           // this file failed; retriable
    case timedOut
    case invalidOutput(String)
}

/// One backend that turns a chunk of text into facts. Availability is checked
/// before use; `extract` is only called when the backend is ready.
public protocol FactExtractor: Sendable {
    func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact]
}

/// The shared extraction instruction, so on-device and agent backends produce
/// comparable results, aligned with the memory taxonomy in AGENTS.md.
public enum ExtractionPrompt {
    public static func build(text: String, context: ExtractionContext) -> String {
        """
        You read a document and extract the durable, reusable information worth \
        remembering about a person in a personal memory store: facts about who they \
        are and their world, their preferences, decisions, plans, and the meaningful \
        records the document contains.

        Be selective. Aim for the smallest set of memories that captures what actually \
        matters; when in doubt, leave it out. Do NOT create a memory for any of these:
        - the document's own title, type, or section headings (e.g. "Registration Card")
        - field labels, table headers, or blank/empty fields
        - signature, authorization, or approval lines
        - page numbers, generation or print timestamps, "generated by" lines, and other \
        boilerplate

        Do capture:
        - the substantive records: if the document lists items in a table (courses, \
        transactions, holdings, tasks, line items), extract EACH meaningful item as its \
        own memory with its key attributes (for a course: name, code, credits)
        - the few framing facts that matter: who it is about, the institution or \
        organization, key identifiers, and totals

        Each memory:
        - "title": a short noun phrase naming the fact, NOT "Label: value". \
        E.g. "Fluid Mechanics course", not "Course 6: Fluid Mechanics".
        - "content": one full, self-contained sentence, third person, present tense, \
        that still makes sense months later without the document.
        - "type": "fact" for biographical/contextual info and records, "preference" for \
        likes, dislikes, and working style, "decision" for choices made, "project" for \
        ongoing work, "note" only when nothing else fits.

        Return ONLY a JSON array (no prose, no markdown code fences). Each item:
        {"title": "...", "content": "...", "type": "fact|preference|decision|project|note", "tags": ["2-4","lowercase","tags"]}

        If there is genuinely nothing worth remembering, return [].
        Do not use any tools; answer directly.

        Source: \(context.sourceName) — \(context.relPath)

        TEXT:
        \(text)
        """
    }
}

/// Tolerant parse of a model's text answer into facts: strips code fences,
/// isolates the outer JSON array, and decodes with a permissive `type`
/// (anything unrecognized falls back to `.note`).
public enum FactParsing {
    private struct RawFact: Decodable {
        var title: String?
        var content: String?
        var type: String?
        var tags: [String]?
    }

    public static func parse(_ raw: String) -> [ExtractedFact] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json ... ``` fences if the model added them.
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                       .replacingOccurrences(of: "```", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Isolate the outer array.
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"),
              start <= end else { return [] }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let rows = try? JSONDecoder().decode([RawFact].self, from: data) else { return [] }

        return rows.compactMap { row in
            guard let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let content = row.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
            else { return nil }
            let type = MemoryType(rawValue: (row.type ?? "note").lowercased()) ?? .note
            let tags = (row.tags ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
            return ExtractedFact(title: title, content: content, type: type, tags: tags)
        }
    }
}
