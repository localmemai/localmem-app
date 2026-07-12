import Foundation

/// Processes one source (one deliberately imported file): read → change-detect
/// → extract → replace-all reconcile → record state. The extractor is injected
/// (Apple on-device or a configured agent). Batch orchestration — the queue,
/// concurrency, and Stop — lives with the caller; the engine only ever touches
/// a single file per call, so a failure never affects other files.
public actor ExtractionEngine {
    private let memoryStore: MemoryStore
    private let sourceStore: SourceStore
    private let reader = FileReader()

    public init(memoryStore: MemoryStore, sourceStore: SourceStore) {
        self.memoryStore = memoryStore
        self.sourceStore = sourceStore
    }

    /// Process the source's file and return the recorded per-file state.
    /// Returns nil when the surrounding task was cancelled before any work
    /// happened — Stop leaves the file exactly as it was.
    ///
    /// Unchanged files (same content hash) are left untouched unless `force`;
    /// otherwise the file's previous memories are replaced with the freshly
    /// extracted set in a per-file transaction.
    @discardableResult
    public func process(source: ImportSource, extractor: FactExtractor, force: Bool) async -> SourceFileState? {
        guard !Task.isCancelled else { return nil }

        let url = URL(fileURLWithPath: source.path)
        let rel = url.lastPathComponent
        let result = reader.read(url, relPath: rel)

        // No text → record the skip/failure, no extraction.
        guard let text = result.text else {
            return await record(SourceFileState(
                relPath: rel, modifiedAt: result.modifiedAt, processedAt: Date(),
                status: result.status, reasonCode: result.reasonCode, error: result.error),
                for: source)
        }

        // Unchanged & not forced → keep existing memories and state.
        if !force, let prev = try? await sourceStore.fileHash(sourceID: source.id, relPath: rel),
           prev == result.sha256 {
            return (try? await sourceStore.listFileStates(sourceID: source.id))?
                .first { $0.relPath == rel }
        }

        do {
            var facts = Self.clean(try await extractor.extract(
                from: text, context: ExtractionContext(sourceName: source.name, relPath: rel)))
            if facts.count > ConnectorLimits.maxFactsPerFile {
                facts = Array(facts.prefix(ConnectorLimits.maxFactsPerFile))
            }

            // Replace-all: swap this file's old memories for the new set in a
            // single transaction — delete + insert + link + audit rows commit
            // (or roll back) together, so an interruption can't lose the old
            // set without landing the new one.
            let memories = facts.map {
                Memory(type: $0.type, title: $0.title, content: $0.content, tags: $0.tags, source: "import")
            }
            try await sourceStore.replaceMemories(
                sourceID: source.id, relPath: rel, with: memories,
                actorKind: .cli, actorID: "import"
            )

            var updated = source
            updated.lastRunAt = Date()
            try? await sourceStore.update(updated)

            return await record(SourceFileState(
                relPath: rel, contentSHA256: result.sha256, modifiedAt: result.modifiedAt,
                processedAt: Date(), status: result.truncated ? .partial : .processed,
                reasonCode: result.reasonCode, error: result.error, factCount: memories.count),
                for: source)
        } catch {
            let (code, message) = Self.describe(error)
            return await record(SourceFileState(
                relPath: rel, modifiedAt: result.modifiedAt, processedAt: Date(),
                status: .failed, reasonCode: code, error: message),
                for: source)
        }
    }

    private func record(_ state: SourceFileState, for source: ImportSource) async -> SourceFileState {
        try? await sourceStore.upsertFileState(sourceID: source.id, state)
        return state
    }

    /// Drop clear boilerplate, then de-duplicate by content.
    private static func clean(_ facts: [ExtractedFact]) -> [ExtractedFact] {
        var seen = Set<String>()
        return facts.filter(BoilerplateFilter.keep).filter {
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
