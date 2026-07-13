import Foundation

/// Processes one source (one deliberately imported file): read → change-detect
/// → extract → deterministic filters → verify → replace-all reconcile → record
/// state. The extractor and verifier are injected (Apple on-device or a
/// configured agent — always the same backend for both passes). Batch
/// orchestration — the queue, concurrency, and Stop — lives with the caller;
/// the engine only ever touches a single file per call, so a failure never
/// affects other files.
///
/// Nothing reaches the vault without passing verification: a verify failure
/// (timeout, error, unmappable output) fails the file with a retriable
/// `verify_*` reason code. See docs/Technical_Design.md section 10.
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
    public func process(source: ImportSource, extractor: FactExtractor,
                        verifier: FactVerifier, force: Bool) async -> SourceFileState? {
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

        let context = ExtractionContext(sourceName: source.name, relPath: rel)

        // PASS 1 — extract (liberal; recall is its only job).
        // Hard deadline on every backend. The agent CLI path also times out
        // internally (ProcessRunner), but the on-device model has no timeout
        // of its own — without this race a hung call would spin forever.
        let extracted: [ExtractedFact]
        do {
            extracted = try await Self.withTimeout(ConnectorLimits.extractionTimeout) {
                try await extractor.extract(from: text, context: context)
            }
        } catch {
            let (code, message) = Self.describe(error)
            return await record(SourceFileState(
                relPath: rel, modifiedAt: result.modifiedAt, processedAt: Date(),
                status: .failed, reasonCode: code, error: message),
                for: source)
        }

        // Deterministic filters — free, so they run BEFORE the second LLM call.
        let candidates = Array(DeterministicFilters.clean(extracted).prefix(ConnectorLimits.maxFactsPerFile))

        // PASS 2 — verify (strict curator, one batched call per file). An empty
        // candidate set is a valid outcome ("nothing worth remembering"), not a
        // failure — skip the call rather than ask the model to judge nothing.
        let kept: [ExtractedFact]
        if candidates.isEmpty {
            kept = []
        } else {
            do {
                let verdicts = try await Self.withTimeout(ConnectorLimits.extractionTimeout) {
                    try await verifier.verify(candidates: candidates, against: text, context: context)
                }
                guard verdicts.count == candidates.count else {
                    throw ExtractionError.invalidOutput("Verifier returned \(verdicts.count) verdicts for \(candidates.count) candidates.")
                }
                kept = Self.apply(verdicts, to: candidates, relPath: rel)
            } catch {
                // Never store unverified facts — the file fails, retriably.
                let (code, message) = Self.describeVerify(error)
                return await record(SourceFileState(
                    relPath: rel, modifiedAt: result.modifiedAt, processedAt: Date(),
                    status: .failed, reasonCode: code, error: message),
                    for: source)
            }
        }

        do {
            // Replace-all: swap this file's old memories for the new set in a
            // single transaction — delete + insert + link + audit rows commit
            // (or roll back) together, so an interruption can't lose the old
            // set without landing the new one.
            let memories = kept.map {
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
                reasonCode: result.reasonCode, error: result.error, factCount: memories.count,
                extractedCount: extracted.count, keptCount: memories.count),
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

    /// Race an operation against a deadline; the loser is cancelled. Throws
    /// `ExtractionError.timedOut` when the deadline wins, so the file is marked
    /// `failed` / `timeout` (retriable) instead of hanging the run.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ExtractionError.timedOut
            }
            guard let first = try await group.next() else { throw ExtractionError.timedOut }
            group.cancelAll()
            return first
        }
    }

    /// keep → as-is, revise → repaired fact, drop → excluded with the reason
    /// debug-logged (never persisted) — free tuning data for the prompts.
    private static func apply(_ verdicts: [FactVerdict], to candidates: [ExtractedFact],
                              relPath: String) -> [ExtractedFact] {
        let (kept, dropped) = VerdictApplication.split(verdicts, candidates: candidates)
        for (candidate, reason) in dropped {
            Log.debug(.store, "verifier dropped candidate", [
                "file": relPath, "title": candidate.title, "reason": reason,
            ])
        }
        return kept
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

    private static func describeVerify(_ error: Error) -> (String, String) {
        if let e = error as? ExtractionError {
            switch e {
            case .timedOut:                return ("verify_timeout", "Verification timed out.")
            case .unavailable(let m):      return ("verify_error", m)
            case .failed(let m):           return ("verify_error", m)
            case .invalidOutput(let m):    return ("verify_invalid_output", m)
            }
        }
        return ("verify_error", error.localizedDescription)
    }
}
