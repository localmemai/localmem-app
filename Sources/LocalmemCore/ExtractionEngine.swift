import Foundation

public struct ExtractionProgress: Sendable {
    public var filesTotal: Int
    public var filesDone: Int
    public var factsAdded: Int
    public var currentFile: String?

    public init(filesTotal: Int, filesDone: Int, factsAdded: Int, currentFile: String?) {
        self.filesTotal = filesTotal
        self.filesDone = filesDone
        self.factsAdded = factsAdded
        self.currentFile = currentFile
    }
}

public struct ExtractionRunSummary: Sendable {
    public var filesProcessed: Int = 0
    public var filesSkipped: Int = 0
    public var filesFailed: Int = 0
    public var factsAdded: Int = 0

    public init(filesProcessed: Int = 0, filesSkipped: Int = 0, filesFailed: Int = 0, factsAdded: Int = 0) {
        self.filesProcessed = filesProcessed
        self.filesSkipped = filesSkipped
        self.filesFailed = filesFailed
        self.factsAdded = factsAdded
    }
}

/// One proposed memory awaiting the user's approval. Carries a stable id so the
/// review UI can track which proposals the user kept, and the `relPath` it came
/// from so commit can reconcile per file.
public struct PreviewFact: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var relPath: String
    public var title: String
    public var content: String
    public var type: MemoryType
    public var tags: [String]

    public init(id: UUID = UUID(), relPath: String, title: String, content: String,
                type: MemoryType, tags: [String]) {
        self.id = id
        self.relPath = relPath
        self.title = title
        self.content = content
        self.type = type
        self.tags = tags
    }
}

/// The would-be outcome for one file, without any of it having been written yet.
/// Carries the read metadata (hash/mtime/truncation) so commit can persist the
/// exact state the user reviewed.
public struct PreviewFileOutcome: Sendable, Equatable {
    public var relPath: String
    public var status: SourceFileState.Status
    public var reasonCode: String?
    public var error: String?
    public var sha256: String?
    public var modifiedAt: Date?
    public var truncated: Bool

    public init(relPath: String, status: SourceFileState.Status, reasonCode: String? = nil,
                error: String? = nil, sha256: String? = nil, modifiedAt: Date? = nil,
                truncated: Bool = false) {
        self.relPath = relPath
        self.status = status
        self.reasonCode = reasonCode
        self.error = error
        self.sha256 = sha256
        self.modifiedAt = modifiedAt
        self.truncated = truncated
    }
}

/// Result of a dry-run extraction: proposed facts the user can approve, the
/// per-file outcomes (incl. skips/failures), and the set of files considered so
/// commit can reconcile removals. Nothing here has touched the store.
public struct ExtractionPreview: Sendable, Equatable {
    public var facts: [PreviewFact]
    public var files: [PreviewFileOutcome]
    public var consideredRelPaths: [String]

    public init(facts: [PreviewFact] = [], files: [PreviewFileOutcome] = [], consideredRelPaths: [String] = []) {
        self.facts = facts
        self.files = files
        self.consideredRelPaths = consideredRelPaths
    }

    public var failedFiles: [PreviewFileOutcome] { files.filter { $0.status == .failed } }
    public var skippedFiles: [PreviewFileOutcome] { files.filter { $0.status == .skipped } }
}

/// Orchestrates a run over a source: read → change-detect → extract → replace-all
/// reconcile → store. Per-file failures never abort the run. The extractor is
/// injected (Apple on-device or a configured agent).
///
/// Two modes: `run` extracts and stores in one shot (used for silent catch-up
/// scans); `preview` + `commit` split extraction from storage so the user can
/// review and approve proposed memories before anything is written.
public actor ExtractionEngine {
    private let memoryStore: MemoryStore
    private let sourceStore: SourceStore
    private let reader = FileReader()

    public init(memoryStore: MemoryStore, sourceStore: SourceStore) {
        self.memoryStore = memoryStore
        self.sourceStore = sourceStore
    }

    public func run(
        source: ImportSource,
        extractor: FactExtractor,
        force: Bool,
        onProgress: @Sendable @escaping (ExtractionProgress) -> Void
    ) async -> ExtractionRunSummary {
        let root = URL(fileURLWithPath: source.path)
        let files = reader.enumerate(root: root, kind: source.kind)
        var progress = ExtractionProgress(filesTotal: files.count, filesDone: 0, factsAdded: 0, currentFile: nil)
        onProgress(progress)

        var summary = ExtractionRunSummary()
        var seen = Set<String>()

        for url in files {
            let rel = reader.relPath(of: url, root: root, kind: source.kind)
            seen.insert(rel)
            progress.currentFile = rel
            onProgress(progress)

            let result = reader.read(url, relPath: rel)

            // No text → record skip/fail, no extraction.
            guard let text = result.text else {
                try? await sourceStore.upsertFileState(sourceID: source.id, SourceFileState(
                    relPath: rel, modifiedAt: result.modifiedAt, processedAt: Date(),
                    status: result.status, reasonCode: result.reasonCode, error: result.error))
                if result.status == .failed { summary.filesFailed += 1 } else { summary.filesSkipped += 1 }
                progress.filesDone += 1; onProgress(progress)
                continue
            }

            // Unchanged & not forced → keep existing memories, skip extraction.
            if !force, let prev = try? await sourceStore.fileHash(sourceID: source.id, relPath: rel),
               prev == result.sha256 {
                summary.filesProcessed += 1
                progress.filesDone += 1; onProgress(progress)
                continue
            }

            do {
                var facts = Self.dedup(try await extractor.extract(
                    from: text, context: ExtractionContext(sourceName: source.name, relPath: rel)))
                if facts.count > ConnectorLimits.maxFactsPerFile {
                    facts = Array(facts.prefix(ConnectorLimits.maxFactsPerFile))
                }

                // Replace-all: drop this file's old memories, insert the new set.
                let old = try await sourceStore.memoryIDs(sourceID: source.id, relPath: rel)
                try await sourceStore.deleteMemories(ids: old)

                let memories = facts.map {
                    Memory(type: $0.type, title: $0.title, content: $0.content, tags: $0.tags, source: "import")
                }
                if !memories.isEmpty {
                    try await memoryStore.importMemories(memories, actorKind: .cli, actorID: "import")
                    for m in memories {
                        try await sourceStore.link(memoryID: m.id, sourceID: source.id, relPath: rel)
                    }
                }

                try await sourceStore.upsertFileState(sourceID: source.id, SourceFileState(
                    relPath: rel, contentSHA256: result.sha256, modifiedAt: result.modifiedAt,
                    processedAt: Date(), status: result.truncated ? .partial : .processed,
                    reasonCode: result.reasonCode, error: result.error))

                summary.filesProcessed += 1
                summary.factsAdded += memories.count
                progress.factsAdded += memories.count
            } catch {
                let (code, message) = Self.describe(error)
                try? await sourceStore.upsertFileState(sourceID: source.id, SourceFileState(
                    relPath: rel, modifiedAt: result.modifiedAt, processedAt: Date(),
                    status: .failed, reasonCode: code, error: message))
                summary.filesFailed += 1
            }

            progress.filesDone += 1
            onProgress(progress)
        }

        // Files that disappeared since last run → drop their memories + state.
        let gone = (try? await sourceStore.removeMissingFileStates(sourceID: source.id, keeping: seen)) ?? []
        for rel in gone {
            let ids = (try? await sourceStore.memoryIDs(sourceID: source.id, relPath: rel)) ?? []
            try? await sourceStore.deleteMemories(ids: ids)
        }

        var updated = source
        updated.lastRunAt = Date()
        try? await sourceStore.update(updated)

        progress.currentFile = nil
        onProgress(progress)
        return summary
    }

    /// Dry run: read and extract, but write nothing. Returns proposed facts for
    /// the user to review. Change-detection still applies — unchanged files are
    /// left untouched and produce no proposals (unless `force`).
    public func preview(
        source: ImportSource,
        extractor: FactExtractor,
        force: Bool,
        onProgress: @Sendable @escaping (ExtractionProgress) -> Void
    ) async -> ExtractionPreview {
        let root = URL(fileURLWithPath: source.path)
        let files = reader.enumerate(root: root, kind: source.kind)
        var progress = ExtractionProgress(filesTotal: files.count, filesDone: 0, factsAdded: 0, currentFile: nil)
        onProgress(progress)

        var facts: [PreviewFact] = []
        var outcomes: [PreviewFileOutcome] = []
        var considered: [String] = []

        for url in files {
            let rel = reader.relPath(of: url, root: root, kind: source.kind)
            considered.append(rel)
            progress.currentFile = rel
            onProgress(progress)

            let result = reader.read(url, relPath: rel)

            // No text → record skip/fail outcome, no proposals.
            guard let text = result.text else {
                outcomes.append(PreviewFileOutcome(
                    relPath: rel, status: result.status, reasonCode: result.reasonCode,
                    error: result.error, sha256: result.sha256, modifiedAt: result.modifiedAt))
                progress.filesDone += 1; onProgress(progress)
                continue
            }

            // Unchanged & not forced → leave existing memories, propose nothing.
            if !force, let prev = try? await sourceStore.fileHash(sourceID: source.id, relPath: rel),
               prev == result.sha256 {
                progress.filesDone += 1; onProgress(progress)
                continue
            }

            do {
                var extracted = Self.dedup(try await extractor.extract(
                    from: text, context: ExtractionContext(sourceName: source.name, relPath: rel)))
                if extracted.count > ConnectorLimits.maxFactsPerFile {
                    extracted = Array(extracted.prefix(ConnectorLimits.maxFactsPerFile))
                }
                for f in extracted {
                    facts.append(PreviewFact(relPath: rel, title: f.title, content: f.content,
                                             type: f.type, tags: f.tags))
                }
                outcomes.append(PreviewFileOutcome(
                    relPath: rel, status: result.truncated ? .partial : .processed,
                    reasonCode: result.reasonCode, error: result.error,
                    sha256: result.sha256, modifiedAt: result.modifiedAt, truncated: result.truncated))
                progress.factsAdded += extracted.count
            } catch {
                let (code, message) = Self.describe(error)
                outcomes.append(PreviewFileOutcome(
                    relPath: rel, status: .failed, reasonCode: code, error: message,
                    sha256: result.sha256, modifiedAt: result.modifiedAt))
            }

            progress.filesDone += 1
            onProgress(progress)
        }

        progress.currentFile = nil
        onProgress(progress)
        return ExtractionPreview(facts: facts, files: outcomes, consideredRelPaths: considered)
    }

    /// Persist the user-approved subset of a preview: replace-all per file, record
    /// file states exactly as previewed, and reconcile removed files. Only facts
    /// whose ids are in `approvedIDs` are stored.
    public func commit(
        source: ImportSource,
        preview: ExtractionPreview,
        approvedIDs: Set<UUID>
    ) async -> ExtractionRunSummary {
        var summary = ExtractionRunSummary()

        let approved = preview.facts.filter { approvedIDs.contains($0.id) }
        let byFile = Dictionary(grouping: approved, by: { $0.relPath })

        for outcome in preview.files {
            let rel = outcome.relPath
            switch outcome.status {
            case .processed, .partial:
                // Replace-all: drop this file's old memories, insert the approved set.
                let old = (try? await sourceStore.memoryIDs(sourceID: source.id, relPath: rel)) ?? []
                try? await sourceStore.deleteMemories(ids: old)

                let memories = (byFile[rel] ?? []).map {
                    Memory(type: $0.type, title: $0.title, content: $0.content, tags: $0.tags, source: "import")
                }
                if !memories.isEmpty {
                    _ = try? await memoryStore.importMemories(memories, actorKind: .cli, actorID: "import")
                    for m in memories {
                        try? await sourceStore.link(memoryID: m.id, sourceID: source.id, relPath: rel)
                    }
                }
                try? await sourceStore.upsertFileState(sourceID: source.id, SourceFileState(
                    relPath: rel, contentSHA256: outcome.sha256, modifiedAt: outcome.modifiedAt,
                    processedAt: Date(), status: outcome.status,
                    reasonCode: outcome.reasonCode, error: outcome.error))
                summary.filesProcessed += 1
                summary.factsAdded += memories.count

            case .failed:
                try? await sourceStore.upsertFileState(sourceID: source.id, SourceFileState(
                    relPath: rel, modifiedAt: outcome.modifiedAt, processedAt: Date(),
                    status: .failed, reasonCode: outcome.reasonCode, error: outcome.error))
                summary.filesFailed += 1

            case .skipped, .pending:
                try? await sourceStore.upsertFileState(sourceID: source.id, SourceFileState(
                    relPath: rel, contentSHA256: outcome.sha256, modifiedAt: outcome.modifiedAt,
                    processedAt: Date(), status: .skipped,
                    reasonCode: outcome.reasonCode, error: outcome.error))
                summary.filesSkipped += 1
            }
        }

        // Files that disappeared since last run → drop their memories + state.
        let gone = (try? await sourceStore.removeMissingFileStates(
            sourceID: source.id, keeping: Set(preview.consideredRelPaths))) ?? []
        for rel in gone {
            let ids = (try? await sourceStore.memoryIDs(sourceID: source.id, relPath: rel)) ?? []
            try? await sourceStore.deleteMemories(ids: ids)
        }

        var updated = source
        updated.lastRunAt = Date()
        try? await sourceStore.update(updated)
        return summary
    }

    private static func dedup(_ facts: [ExtractedFact]) -> [ExtractedFact] {
        var seen = Set<String>()
        return facts.filter {
            seen.insert($0.content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)).inserted
        }
    }

    private static func describe(_ error: Error) -> (String, String) {
        if let e = error as? ExtractionError {
            switch e {
            case .timedOut:                return ("timeout", "Extraction timed out.")
            case .unavailable(let m):      return ("extractor_unavailable", m)
            case .failed(let m):           return ("extractor_error", m)
            case .invalidOutput(let m):    return ("invalid_output", m)
            }
        }
        return ("extractor_error", error.localizedDescription)
    }
}
