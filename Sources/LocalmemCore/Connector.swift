import Foundation

// MARK: - Limits

/// Guardrails so one huge/pathological file can't hang the app, exhaust memory,
/// flood the store, or run up agent cost. See docs/Technical_Design.md section 10.
public enum ConnectorLimits {
    public static let maxFileSizeBytes = 20 * 1024 * 1024        // 20 MB — the PDF guard
    public static let maxTextChars = 1_000_000                    // ~1 MB of text per file
    public static let maxFactsPerFile = 200
    public static let maxFilesPerBatch = 5_000                    // sanity cap on one panel selection
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

/// A file the user deliberately imported memories from. One source per file —
/// nothing is ever processed without an explicit user gesture (add, reprocess),
/// so there is no folder walking, watching, or pause state.
public struct ImportSource: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var connector: String
    public var path: String
    public var bookmark: Data?
    public var backend: ExtractionBackend
    public var lastRunAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        connector: String = "files",
        path: String,
        bookmark: Data? = nil,
        backend: ExtractionBackend,
        lastRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.connector = connector
        self.path = path
        self.bookmark = bookmark
        self.backend = backend
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Per-file processing state, for change detection and the detail view.
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
    /// Raw Pass-1 candidate count, before deterministic filters — the "N" in
    /// the "N extracted → M kept" transparency line. nil on rows processed
    /// before the verify pass shipped.
    public var extractedCount: Int?
    /// Post-verification stored count — the "M". nil pre-verify-pass.
    public var keptCount: Int?

    public var id: String { relPath }

    public init(relPath: String, contentSHA256: String? = nil, modifiedAt: Date? = nil,
                processedAt: Date? = nil, status: Status, reasonCode: String? = nil,
                error: String? = nil, factCount: Int = 0,
                extractedCount: Int? = nil, keptCount: Int? = nil) {
        self.relPath = relPath
        self.contentSHA256 = contentSHA256
        self.modifiedAt = modifiedAt
        self.processedAt = processedAt
        self.status = status
        self.reasonCode = reasonCode
        self.error = error
        self.factCount = factCount
        self.extractedCount = extractedCount
        self.keptCount = keptCount
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

/// The shared Pass-1 extraction instruction, so on-device and agent backends
/// produce comparable results, aligned with the memory taxonomy in AGENTS.md.
///
/// Deliberately liberal: recall is this pass's only job. A strict verifier
/// (`VerificationPrompt`) judges every candidate afterwards, so this prompt no
/// longer carries the contradictory "be selective / extract EACH item" tension
/// or the boilerplate blocklists — the deterministic filter and the verifier
/// own precision now. See docs/Technical_Design.md section 10.
public enum ExtractionPrompt {
    /// The task rubric shared by both prompt variants.
    static let rubric = """
        You read a document and propose candidate memories for a personal memory \
        store: durable facts about who the person is and their world, their \
        preferences, decisions, plans, and ongoing work. A separate curation pass \
        will judge your candidates, so when something might matter, include it — \
        prefer proposing too much over missing a real fact.

        Each candidate:
        - "title": a short noun phrase naming the fact, NOT "Label: value". \
        E.g. "Fluid Mechanics course", not "Course 6: Fluid Mechanics".
        - "content": one full, self-contained sentence, third person, present tense, \
        that still makes sense months later without the document.
        - "type": "fact" for biographical/contextual info and records, "preference" for \
        likes, dislikes, and working style, "decision" for choices made, "project" for \
        ongoing work, "note" only when nothing else fits.
        """

    public static func build(text: String, context: ExtractionContext) -> String {
        """
        \(rubric)

        Return ONLY a JSON array (no prose, no markdown code fences). Each item:
        {"title": "...", "content": "...", "type": "fact|preference|decision|project|note", "tags": ["2-4","lowercase","tags"]}

        Example — notes snippet "Switched the team to Linear last week. I'm off \
        dairy for a while, doctor's orders." →
        [{"title": "Linear adoption", "content": "Moved the team's issue tracking to Linear.", "type": "decision", "tags": ["tools", "workflow"]},
         {"title": "Dairy-free diet", "content": "Is avoiding dairy on medical advice.", "type": "fact", "tags": ["diet", "health", "food"]}]

        Example — a page containing only navigation links and a copyright footer →
        []

        If there is genuinely nothing worth remembering, return [].
        Do not use any tools; answer directly.

        Source: \(context.sourceName) — \(context.relPath)

        TEXT:
        \(text)
        """
    }

    /// Variant for guided generation (the on-device backend): the response
    /// format is enforced by constrained decoding, so the prompt carries no
    /// JSON syntax — describing a second format would only confuse the model.
    public static func guided(text: String, context: ExtractionContext) -> String {
        """
        \(rubric)

        Example — notes snippet "Switched the team to Linear last week. I'm off \
        dairy for a while, doctor's orders." → two candidates: a "decision" titled \
        "Linear adoption" ("Moved the team's issue tracking to Linear."), and a \
        "fact" titled "Dairy-free diet" ("Is avoiding dairy on medical advice.").

        Give each candidate 2-4 lowercase tags. If there is genuinely nothing \
        worth remembering, return an empty list.

        Source: \(context.sourceName) — \(context.relPath)

        TEXT:
        \(text)
        """
    }
}

/// A deterministic safety net that drops unmistakable boilerplate a weaker model
/// may propose despite the prompt — signature/authorization lines, generation and
/// print metadata, page numbers, and empty or label-only facts. Kept
/// high-precision on purpose: it only rejects clear junk so it can't discard a
/// legitimate memory. Applied to every backend before the user reviews.
public enum BoilerplateFilter {
    /// Substrings that only appear in document boilerplate, matched
    /// case-insensitively against "title. content".
    private static let junkPhrases = [
        "signature of", "signed by", "authorized signatory", "authorised signatory",
        "for office use", "generation date", "generated by", "generated on",
        "date generated", "was generated", "print date", "printed on", "printed by",
    ]

    public static func keep(_ fact: ExtractedFact) -> Bool { !isBoilerplate(fact) }

    public static func isBoilerplate(_ fact: ExtractedFact) -> Bool {
        let title = fact.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = fact.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty or label-only ("Roll No." → "Roll No.") facts carry nothing.
        if content.isEmpty { return true }
        if content.caseInsensitiveCompare(title) == .orderedSame { return true }

        let hay = "\(title). \(content)".lowercased()
        if junkPhrases.contains(where: hay.contains) { return true }

        // "Page 2 of 5" style footers.
        if hay.range(of: #"\bpage\s+\d+\s+of\s+\d+\b"#, options: .regularExpression) != nil { return true }

        return false
    }
}

/// The deterministic step between the two LLM passes: drop clear boilerplate,
/// then de-duplicate by normalized content. Free, so it runs BEFORE the verify
/// call. Shared by the engine and the eval harness so both score the same
/// pipeline.
public enum DeterministicFilters {
    public static func clean(_ facts: [ExtractedFact]) -> [ExtractedFact] {
        var seen = Set<String>()
        return facts.filter(BoilerplateFilter.keep).filter {
            seen.insert($0.content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)).inserted
        }
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
