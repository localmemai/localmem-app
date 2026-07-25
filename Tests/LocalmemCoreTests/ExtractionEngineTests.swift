import Foundation
import Testing
@testable import LocalmemCore

private struct MockExtractor: FactExtractor {
    let facts: [ExtractedFact]
    func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact] { facts }
}

private struct ThrowingExtractor: FactExtractor {
    func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact] {
        throw ExtractionError.failed("boom")
    }
}

/// Records whether extraction was invoked at all (for change-detection tests).
private final class CountingExtractor: FactExtractor, @unchecked Sendable {
    var calls = 0
    func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact] {
        calls += 1
        return [ExtractedFact(title: "T", content: "C.", type: .fact, tags: [])]
    }
}

/// Default Pass-2 stand-in: verifies everything as-is.
private struct KeepAllVerifier: FactVerifier {
    func verify(candidates: [ExtractedFact], against text: String,
                context: ExtractionContext) async throws -> [FactVerdict] {
        candidates.map { _ in .keep }
    }
}

/// Returns a fixed verdict list regardless of candidates.
private struct FixedVerifier: FactVerifier {
    let verdicts: [FactVerdict]
    func verify(candidates: [ExtractedFact], against text: String,
                context: ExtractionContext) async throws -> [FactVerdict] {
        verdicts
    }
}

private struct ThrowingVerifier: FactVerifier {
    let error: Error
    func verify(candidates: [ExtractedFact], against text: String,
                context: ExtractionContext) async throws -> [FactVerdict] {
        throw error
    }
}

/// Records whether the verify pass ran at all.
private final class CountingVerifier: FactVerifier, @unchecked Sendable {
    var calls = 0
    func verify(candidates: [ExtractedFact], against text: String,
                context: ExtractionContext) async throws -> [FactVerdict] {
        calls += 1
        return candidates.map { _ in .keep }
    }
}

@Suite("ExtractionEngine")
struct ExtractionEngineTests {
    private func makeStores() throws -> (MemoryStore, SourceStore) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lm-conn-\(UUID().uuidString).sqlite3")
        let db = try LocalmemDatabase(url: url)
        return (MemoryStore(database: db), SourceStore(database: db))
    }

    private func makeFile(_ name: String, _ body: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lm-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeSource(_ url: URL) -> ImportSource {
        ImportSource(name: url.lastPathComponent, path: url.path, backend: .apple)
    }

    private func fact(_ title: String, _ content: String) -> ExtractedFact {
        ExtractedFact(title: title, content: content, type: .fact, tags: ["t"])
    }

    @Test("Processing a file stores extracted facts as memories linked to it")
    func storesAndLinks() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("a.md", "some content")
        let source = makeSource(url)
        try await sourceStore.add(source)

        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)
        let state = await engine.process(
            source: source,
            extractor: MockExtractor(facts: [fact("One", "Fact one."), fact("Two", "Fact two.")]),
            verifier: KeepAllVerifier(),
            force: true)

        #expect(state?.status == .processed)
        #expect(state?.factCount == 2)
        #expect(try await memoryStore.count() == 2)
        #expect(try await sourceStore.listFileStates(sourceID: source.id).first?.factCount == 2)
        let all = try await memoryStore.all()
        #expect(all.allSatisfy { $0.source == "import" })
    }

    @Test("Reprocessing replaces the file's memories (replace-all)")
    func replaceAllOnReprocess() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("note.md", "v1")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        _ = await engine.process(source: source,
            extractor: MockExtractor(facts: [fact("A", "A."), fact("B", "B."), fact("C", "C.")]),
            verifier: KeepAllVerifier(), force: true)
        #expect(try await memoryStore.count() == 3)

        // Change the file so the hash differs, then reprocess with fewer facts.
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        _ = await engine.process(source: source,
            extractor: MockExtractor(facts: [fact("Z", "Z.")]),
            verifier: KeepAllVerifier(), force: false)
        #expect(try await memoryStore.count() == 1)
        #expect(try await memoryStore.all().first?.content == "Z.")
    }

    @Test("An unchanged file is not re-extracted unless forced")
    func unchangedFileIsSkipped() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("same.md", "stable content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)
        let extractor = CountingExtractor()

        _ = await engine.process(source: source, extractor: extractor, verifier: KeepAllVerifier(), force: true)
        let second = await engine.process(source: source, extractor: extractor, verifier: KeepAllVerifier(), force: false)

        #expect(extractor.calls == 1)
        #expect(second?.status == .processed)     // previous state is returned
        #expect(try await memoryStore.count() == 1)
    }

    @Test("An extractor failure marks the file failed without adding memories")
    func extractorFailureIsRecorded() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("x.txt", "text")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let state = await engine.process(source: source, extractor: ThrowingExtractor(),
                                         verifier: KeepAllVerifier(), force: true)
        #expect(state?.status == .failed)
        #expect(state?.reasonCode == "extractor_error")
        #expect(try await memoryStore.count() == 0)
        let states = try await sourceStore.listFileStates(sourceID: source.id)
        #expect(states.first?.status == .failed)
    }

    @Test("A missing file is recorded as failed with a 'missing' reason")
    func missingFileIsRecorded() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("gone.md", "content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        try FileManager.default.removeItem(at: url)

        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)
        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: [fact("A", "A.")]), verifier: KeepAllVerifier(), force: true)

        #expect(state?.status == .failed)
        #expect(state?.reasonCode == "missing")
        #expect(try await memoryStore.count() == 0)
    }

    @Test("An unsupported file type is skipped, not failed")
    func unsupportedIsSkipped() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("blob.bin", "binary-ish")
        let source = makeSource(url)
        try await sourceStore.add(source)

        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)
        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: [fact("A", "A.")]), verifier: KeepAllVerifier(), force: true)

        #expect(state?.status == .skipped)
        #expect(state?.reasonCode == "unsupported")
        #expect(try await memoryStore.count() == 0)
    }

    @Test("A cancelled task leaves the file untouched")
    func cancelledTaskDoesNothing() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("later.md", "content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let task = Task {
            await engine.process(source: source,
                extractor: MockExtractor(facts: [fact("A", "A.")]), verifier: KeepAllVerifier(), force: true)
        }
        task.cancel()
        let state = await task.value

        #expect(state == nil)
        #expect(try await memoryStore.count() == 0)
        #expect(try await sourceStore.listFileStates(sourceID: source.id).isEmpty)
    }

    @Test("Boilerplate facts are filtered out before storing")
    func boilerplateIsFiltered() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("card.md", "content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let facts = [
            fact("IIT enrollment", "Is enrolled at IIT Kharagpur."),        // keep
            ExtractedFact(title: "Signature of HOD/HOS/HOC", content: "Signature of the Head of Department.", type: .fact, tags: []),
            ExtractedFact(title: "Generation Date", content: "Jul 8, 2026 10:21 AM. Generated by ERP.", type: .fact, tags: []),
            ExtractedFact(title: "Roll No.", content: "Roll No.", type: .fact, tags: []),  // label-only
        ]
        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: facts), verifier: KeepAllVerifier(), force: true)

        #expect(state?.factCount == 1)
        #expect(try await memoryStore.all().first?.content == "Is enrolled at IIT Kharagpur.")
    }

    @Test("The boilerplate filter keeps ordinary facts")
    func filterKeepsRealFacts() {
        #expect(BoilerplateFilter.keep(ExtractedFact(title: "Fluid Mechanics course",
            content: "Is taking Fluid Mechanics (ME21201), a 4-credit course.", type: .fact, tags: [])))
        #expect(BoilerplateFilter.isBoilerplate(ExtractedFact(title: "Signature of Student in full",
            content: "Signature of Vidit Gupta.", type: .fact, tags: [])))
        #expect(BoilerplateFilter.isBoilerplate(ExtractedFact(title: "Footer",
            content: "Page 2 of 5", type: .fact, tags: [])))
    }

    // MARK: - Verify pass (docs/Technical_Design.md section 10)

    @Test("Verifier verdicts are applied: keep stays, revise replaces, drop excludes")
    func verdictsAreApplied() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("v.md", "content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let repaired = ExtractedFact(title: "Coffee preference",
            content: "Prefers flat white with oat milk.", type: .preference, tags: ["coffee"])
        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: [
                fact("Keep me", "A durable fact."),
                fact("Coffee: flat white", "flat white oat milk"),
                fact("Page header", "A transactional line item."),
            ]),
            verifier: FixedVerifier(verdicts: [
                .keep,
                .revise(repaired),
                .drop(reason: "transactional"),
            ]),
            force: true)

        #expect(state?.status == .processed)
        #expect(state?.factCount == 2)
        let contents = Set(try await memoryStore.all().map(\.content))
        #expect(contents == ["A durable fact.", "Prefers flat white with oat milk."])
    }

    @Test("Extracted/kept counts are recorded: raw Pass-1 count → stored count")
    func countsAreRecorded() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("c.md", "content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        // 3 raw candidates; one is boilerplate (filtered deterministically,
        // never reaches the verifier), one is dropped by the verifier.
        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: [
                fact("A", "First real fact."),
                fact("B", "Second real fact."),
                ExtractedFact(title: "Roll No.", content: "Roll No.", type: .fact, tags: []),
            ]),
            verifier: FixedVerifier(verdicts: [.keep, .drop(reason: "not durable")]),
            force: true)

        #expect(state?.extractedCount == 3)
        #expect(state?.keptCount == 1)
        #expect(state?.factCount == 1)

        // And the counts round-trip through the store.
        let persisted = try await sourceStore.listFileStates(sourceID: source.id).first
        #expect(persisted?.extractedCount == 3)
        #expect(persisted?.keptCount == 1)
    }

    @Test("A verifier failure fails the file retriably — no unverified facts stored")
    func verifierFailureFailsFile() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("vf.md", "content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: [fact("A", "A real fact.")]),
            verifier: ThrowingVerifier(error: ExtractionError.failed("model hiccup")),
            force: true)

        #expect(state?.status == .failed)
        #expect(state?.reasonCode == "verify_error")
        #expect(try await memoryStore.count() == 0)
    }

    @Test("Unmappable verifier output fails the file with verify_invalid_output")
    func invalidVerifierOutputFailsFile() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("vi.md", "content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        // Two candidates, one verdict → the count guard must fail the file.
        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: [fact("A", "First fact."), fact("B", "Second fact.")]),
            verifier: FixedVerifier(verdicts: [.keep]),
            force: true)

        #expect(state?.status == .failed)
        #expect(state?.reasonCode == "verify_invalid_output")
        #expect(try await memoryStore.count() == 0)
    }

    @Test("An empty candidate set is a valid processed outcome and skips the verify call")
    func emptyCandidatesSkipVerifier() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("empty.md", "nothing memorable")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)
        let verifier = CountingVerifier()

        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: []), verifier: verifier, force: true)

        #expect(state?.status == .processed)
        #expect(state?.extractedCount == 0)
        #expect(state?.keptCount == 0)
        #expect(verifier.calls == 0)
        #expect(try await memoryStore.count() == 0)
        // Success with zero facts must carry a reason the UI can show.
        #expect(state?.reasonCode == "no_facts")
        #expect(state?.error?.contains("No personal facts found") == true)
    }

    @Test("All candidates dropped by the verifier is still a processed file")
    func allDroppedIsProcessed() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let url = try makeFile("junk.md", "content")
        let source = makeSource(url)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let state = await engine.process(source: source,
            extractor: MockExtractor(facts: [fact("A", "Junk one."), fact("B", "Junk two.")]),
            verifier: FixedVerifier(verdicts: [.drop(reason: "junk"), .drop(reason: "junk")]),
            force: true)

        #expect(state?.status == .processed)
        #expect(state?.extractedCount == 2)
        #expect(state?.keptCount == 0)
        #expect(try await memoryStore.count() == 0)
        // The all-dropped case explains itself via the curation wording.
        #expect(state?.reasonCode == "no_facts")
        #expect(state?.error?.contains("curation dropped every candidate") == true)
    }
}
