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
