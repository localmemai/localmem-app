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

/// Orchestrates a run over a source: read → change-detect → extract → replace-all
/// reconcile → store. Per-file failures never abort the run. The extractor is
/// injected (Apple on-device or a configured agent).
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
