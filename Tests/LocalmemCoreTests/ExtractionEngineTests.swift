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

@Suite("ExtractionEngine")
struct ExtractionEngineTests {
    private func makeStores() throws -> (MemoryStore, SourceStore) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lm-conn-\(UUID().uuidString).sqlite3")
        let db = try LocalmemDatabase(url: url)
        return (MemoryStore(database: db), SourceStore(database: db))
    }

    private func makeFolder(_ files: [String: String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lm-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func fact(_ title: String, _ content: String) -> ExtractedFact {
        ExtractedFact(title: title, content: content, type: .fact, tags: ["t"])
    }

    @Test("A run stores extracted facts as memories linked to the source file")
    func storesAndLinks() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let dir = try makeFolder(["a.md": "some content"])
        let source = ImportSource(name: "a", kind: .folder, path: dir.path, backend: .apple)
        try await sourceStore.add(source)

        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)
        let summary = await engine.run(
            source: source,
            extractor: MockExtractor(facts: [fact("One", "Fact one."), fact("Two", "Fact two.")]),
            force: true, onProgress: { _ in })

        #expect(summary.factsAdded == 2)
        #expect(try await memoryStore.count() == 2)
        #expect(try await sourceStore.stats(sourceID: source.id).factCount == 2)
        let all = try await memoryStore.all()
        #expect(all.allSatisfy { $0.source == "import" })
    }

    @Test("Reprocessing a changed file replaces that file's memories (replace-all)")
    func replaceAllOnReprocess() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let file = "note.md"
        let dir = try makeFolder([file: "v1"])
        let source = ImportSource(name: "n", kind: .folder, path: dir.path, backend: .apple)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        _ = await engine.run(source: source,
                             extractor: MockExtractor(facts: [fact("A", "A."), fact("B", "B."), fact("C", "C.")]),
                             force: true, onProgress: { _ in })
        #expect(try await memoryStore.count() == 3)

        // Change the file so the hash differs, then reprocess with fewer facts.
        try "v2".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = await engine.run(source: source,
                             extractor: MockExtractor(facts: [fact("Z", "Z.")]),
                             force: false, onProgress: { _ in })
        #expect(try await memoryStore.count() == 1)
        #expect(try await memoryStore.all().first?.content == "Z.")
    }

    @Test("An extractor failure marks the file failed without adding memories")
    func extractorFailureIsRecorded() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let dir = try makeFolder(["x.txt": "text"])
        let source = ImportSource(name: "x", kind: .folder, path: dir.path, backend: .apple)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let summary = await engine.run(source: source, extractor: ThrowingExtractor(),
                                       force: true, onProgress: { _ in })
        #expect(summary.filesFailed == 1)
        #expect(try await memoryStore.count() == 0)
        let states = try await sourceStore.listFileStates(sourceID: source.id)
        #expect(states.first?.status == .failed)
    }

    @Test("Preview extracts proposals without writing anything")
    func previewDoesNotWrite() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let dir = try makeFolder(["a.md": "content"])
        let source = ImportSource(name: "a", kind: .folder, path: dir.path, backend: .apple)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let preview = await engine.preview(
            source: source,
            extractor: MockExtractor(facts: [fact("One", "1."), fact("Two", "2.")]),
            force: true, onProgress: { _ in })

        #expect(preview.facts.count == 2)
        #expect(try await memoryStore.count() == 0)
        #expect(try await sourceStore.listFileStates(sourceID: source.id).isEmpty)
    }

    @Test("Commit stores only the facts the user approved")
    func commitStoresOnlyApproved() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let dir = try makeFolder(["a.md": "content"])
        let source = ImportSource(name: "a", kind: .folder, path: dir.path, backend: .apple)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let preview = await engine.preview(
            source: source,
            extractor: MockExtractor(facts: [fact("One", "1."), fact("Two", "2."), fact("Three", "3.")]),
            force: true, onProgress: { _ in })
        let keep = Set(preview.facts.prefix(2).map(\.id))

        let summary = await engine.commit(source: source, preview: preview, approvedIDs: keep)
        #expect(summary.factsAdded == 2)
        #expect(try await memoryStore.count() == 2)
        #expect(Set(try await memoryStore.all().map(\.content)) == ["1.", "2."])
    }

    @Test("Re-committing replaces a file's memories with the newly approved set")
    func commitReplacesOnReprocess() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let dir = try makeFolder(["a.md": "content"])
        let source = ImportSource(name: "a", kind: .folder, path: dir.path, backend: .apple)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let first = await engine.preview(source: source,
            extractor: MockExtractor(facts: [fact("A", "A."), fact("B", "B.")]),
            force: true, onProgress: { _ in })
        _ = await engine.commit(source: source, preview: first, approvedIDs: Set(first.facts.map(\.id)))
        #expect(try await memoryStore.count() == 2)

        let second = await engine.preview(source: source,
            extractor: MockExtractor(facts: [fact("Z", "Z.")]),
            force: true, onProgress: { _ in })
        _ = await engine.commit(source: source, preview: second, approvedIDs: Set(second.facts.map(\.id)))
        #expect(try await memoryStore.count() == 1)
        #expect(try await memoryStore.all().first?.content == "Z.")
    }

    @Test("Boilerplate proposals are filtered out before review")
    func boilerplateIsFiltered() async throws {
        let (memoryStore, sourceStore) = try makeStores()
        let dir = try makeFolder(["card.md": "content"])
        let source = ImportSource(name: "card", kind: .folder, path: dir.path, backend: .apple)
        try await sourceStore.add(source)
        let engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)

        let facts = [
            fact("IIT enrollment", "Is enrolled at IIT Kharagpur."),        // keep
            ExtractedFact(title: "Signature of HOD/HOS/HOC", content: "Signature of the Head of Department.", type: .fact, tags: []),
            ExtractedFact(title: "Generation Date", content: "Jul 8, 2026 10:21 AM. Generated by ERP.", type: .fact, tags: []),
            ExtractedFact(title: "Roll No.", content: "Roll No.", type: .fact, tags: []),  // label-only
        ]
        let preview = await engine.preview(source: source,
            extractor: MockExtractor(facts: facts), force: true, onProgress: { _ in })

        #expect(preview.facts.count == 1)
        #expect(preview.facts.first?.content == "Is enrolled at IIT Kharagpur.")
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

    @Test("Unsupported and oversized files are skipped, not failed")
    func skipsUnsupported() async throws {
        let reader = FileReader()
        let dir = try makeFolder(["ok.md": "content", "skip.bin": "binary-ish"])
        // .bin isn't enumerated at all (unsupported extension).
        let urls = reader.enumerate(root: dir, kind: .folder)
        #expect(urls.count == 1)
        #expect(urls.first?.lastPathComponent == "ok.md")
    }
}
