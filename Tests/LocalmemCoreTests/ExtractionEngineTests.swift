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
            force: true)
        #expect(try await memoryStore.count() == 3)

        // Change the file so the hash differs, then reprocess with fewer facts.
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        _ = await engine.process(source: source,
            extractor: MockExtractor(facts: [fact("Z", "Z.")]),
            force: false)
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

        _ = await engine.process(source: source, extractor: extractor, force: true)
        let second = await engine.process(source: source, extractor: extractor, force: false)

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

        let state = await engine.process(source: source, extractor: ThrowingExtractor(), force: true)
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
            extractor: MockExtractor(facts: [fact("A", "A.")]), force: true)

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
            extractor: MockExtractor(facts: [fact("A", "A.")]), force: true)

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
                extractor: MockExtractor(facts: [fact("A", "A.")]), force: true)
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
            extractor: MockExtractor(facts: facts), force: true)

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
}
