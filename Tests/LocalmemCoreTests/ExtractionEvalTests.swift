import Foundation
import Testing
@testable import LocalmemCore

/// The deterministic pieces of the eval harness (loading, matching, metrics)
/// belong in CI; the LLM-hitting runs stay manual (`localmem eval-extraction`).
@Suite("ExtractionEval")
struct ExtractionEvalTests {

    private func fact(_ content: String) -> ExtractedFact {
        ExtractedFact(title: "T", content: content, type: .fact, tags: [])
    }

    // MARK: Similarity

    @Test("similarity is 1 for identical content and 0 for disjoint content")
    func similarityExtremes() {
        #expect(ExtractionEval.similarity("Prefers flat white with oat milk.",
                                          "prefers flat white with oat milk") == 1)
        #expect(ExtractionEval.similarity("Prefers flat white with oat milk.",
                                          "Ships the ingest cutover in August.") == 0)
    }

    @Test("similarity survives rephrasing above the match threshold")
    func similarityRephrasing() {
        let s = ExtractionEval.similarity(
            "Is learning Rust with about 30 minutes of Rustlings exercises daily.",
            "Learning Rust, doing Rustlings exercises about 30 minutes every day.")
        #expect(s >= 0.5)
    }

    // MARK: Scoring

    @Test("a perfect run scores zero junk, zero lost, zero duplicates")
    func perfectRun() {
        let expected = [ExpectedMemory(content: "Prefers flat white with oat milk.")]
        let m = ExtractionEval.score(actual: [fact("Prefers flat white with oat milk.")],
                                     expected: expected)
        #expect(m.junkKept == 0 && m.goodLost == 0 && m.duplicates == 0)
    }

    @Test("junk, lost, and duplicates are each counted")
    func mixedRun() {
        let expected = [
            ExpectedMemory(content: "Prefers flat white with oat milk."),
            ExpectedMemory(content: "Backend engineer with nine years of Go experience."),
        ]
        let actual = [
            fact("Prefers flat white with oat milk."),                    // match
            fact("Prefers a flat white made with oat milk."),             // duplicate of the same expected
            fact("The document was generated on July 8."),                // junk
            // "Backend engineer…" never produced → lost
        ]
        let m = ExtractionEval.score(actual: actual, expected: expected)
        #expect(m.junkKept == 1)
        #expect(m.duplicates == 1)
        #expect(m.goodLost == 1)
        #expect(m.junkKeptRate == 1.0 / 3.0)
        #expect(m.goodLostRate == 0.5)
    }

    @Test("an empty expected set treats every kept fact as junk")
    func emptyExpected() {
        let m = ExtractionEval.score(actual: [fact("Netflix subscription costs 15.49.")],
                                     expected: [])
        #expect(m.junkKept == 1)
        #expect(m.goodLostRate == 0)   // nothing to lose
    }

    @Test("an empty actual set loses everything and keeps no junk")
    func emptyActual() {
        let m = ExtractionEval.score(actual: [],
                                     expected: [ExpectedMemory(content: "A real fact.")])
        #expect(m.junkKeptRate == 0)
        #expect(m.goodLostRate == 1)
    }

    // MARK: Fixture loading

    @Test("the golden fixture set loads with its expected sets")
    func goldenFixturesLoad() throws {
        let dir = try #require(Bundle.module.url(forResource: "Fixtures/extraction", withExtension: nil))
        let fixtures = try ExtractionEval.loadFixtures(from: dir)

        #expect(fixtures.count == 7)
        let byName = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.name, $0) })

        // The two all-noise documents expect nothing.
        #expect(byName["bank_statement"]?.expected.isEmpty == true)
        #expect(byName["third_party_resume"]?.expected.isEmpty == true)

        // The substantive documents expect real memories.
        #expect((byName["personal_notes"]?.expected.count ?? 0) >= 3)
        #expect((byName["resume"]?.expected.count ?? 0) >= 4)
        #expect((byName["registration_card"]?.expected.count ?? 0) >= 2)
        #expect(byName["boilerplate_scan"]?.expected.count == 1)

        // Every fixture carries its document text.
        #expect(fixtures.allSatisfy { !$0.text.isEmpty })
    }
}
