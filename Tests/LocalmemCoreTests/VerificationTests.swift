import Foundation
import Testing
@testable import LocalmemCore

@Suite("VerdictParsing")
struct VerdictParsingTests {

    private func candidates(_ n: Int) -> [ExtractedFact] {
        (0..<n).map {
            ExtractedFact(title: "T\($0)", content: "Content \($0).", type: .fact, tags: ["t"])
        }
    }

    @Test("keep / revise / drop parse into verdicts in candidate order")
    func parsesAllVerdictKinds() throws {
        let raw = """
        [
          {"index": 0, "verdict": "keep"},
          {"index": 1, "verdict": "revise", "title": "Better title", "content": "Better content.", "type": "preference", "tags": ["coffee"], "reason": "title was a label"},
          {"index": 2, "verdict": "drop", "reason": "table row / transactional"}
        ]
        """
        let verdicts = try #require(VerdictParsing.parse(raw, candidates: candidates(3)))
        #expect(verdicts[0] == .keep)
        #expect(verdicts[1] == .revise(ExtractedFact(
            title: "Better title", content: "Better content.", type: .preference, tags: ["coffee"])))
        #expect(verdicts[2] == .drop(reason: "table row / transactional"))
    }

    @Test("out-of-order verdicts are returned in candidate order")
    func reordersByIndex() throws {
        let raw = """
        [{"index": 1, "verdict": "drop", "reason": "x"}, {"index": 0, "verdict": "keep"}]
        """
        let verdicts = try #require(VerdictParsing.parse(raw, candidates: candidates(2)))
        #expect(verdicts[0] == .keep)
        #expect(verdicts[1] == .drop(reason: "x"))
    }

    @Test("markdown fences and surrounding prose are tolerated")
    func stripsFencesAndProse() throws {
        let raw = """
        Here are my verdicts:
        ```json
        [{"index": 0, "verdict": "keep"}]
        ```
        """
        let verdicts = try #require(VerdictParsing.parse(raw, candidates: candidates(1)))
        #expect(verdicts == [.keep])
    }

    @Test("a revise that only fixes the title keeps the original content, type, and tags")
    func reviseFallsBackFieldwise() throws {
        let original = ExtractedFact(title: "bad", content: "Good content.", type: .decision, tags: ["a", "b"])
        let raw = """
        [{"index": 0, "verdict": "revise", "title": "Good title"}]
        """
        let verdicts = try #require(VerdictParsing.parse(raw, candidates: [original]))
        #expect(verdicts[0] == .revise(ExtractedFact(
            title: "Good title", content: "Good content.", type: .decision, tags: ["a", "b"])))
    }

    @Test("a drop without a reason defaults rather than failing the parse")
    func dropWithoutReason() throws {
        let verdicts = try #require(VerdictParsing.parse(
            #"[{"index": 0, "verdict": "drop"}]"#, candidates: candidates(1)))
        #expect(verdicts == [.drop(reason: "unspecified")])
    }

    // MARK: Fail-closed: anything that can't be mapped 1:1 is nil

    @Test("missing a candidate index → nil (partial coverage means unverified facts)")
    func missingIndexFails() {
        #expect(VerdictParsing.parse(
            #"[{"index": 0, "verdict": "keep"}]"#, candidates: candidates(2)) == nil)
    }

    @Test("a duplicate index → nil")
    func duplicateIndexFails() {
        #expect(VerdictParsing.parse(
            #"[{"index": 0, "verdict": "keep"}, {"index": 0, "verdict": "drop", "reason": "x"}]"#,
            candidates: candidates(2)) == nil)
    }

    @Test("an out-of-range index → nil")
    func outOfRangeIndexFails() {
        #expect(VerdictParsing.parse(
            #"[{"index": 0, "verdict": "keep"}, {"index": 5, "verdict": "keep"}]"#,
            candidates: candidates(2)) == nil)
    }

    @Test("an unknown verdict value → nil")
    func unknownVerdictFails() {
        #expect(VerdictParsing.parse(
            #"[{"index": 0, "verdict": "maybe"}]"#, candidates: candidates(1)) == nil)
    }

    @Test("non-JSON output → nil")
    func garbageFails() {
        #expect(VerdictParsing.parse("I could not decide.", candidates: candidates(1)) == nil)
    }
}

@Suite("VerdictApplication")
struct VerdictApplicationTests {
    @Test("split keeps, replaces revisions, and returns drops with reasons")
    func splitAppliesVerdicts() {
        let a = ExtractedFact(title: "A", content: "A.", type: .fact, tags: [])
        let b = ExtractedFact(title: "B", content: "B.", type: .fact, tags: [])
        let c = ExtractedFact(title: "C", content: "C.", type: .fact, tags: [])
        let repaired = ExtractedFact(title: "B fixed", content: "B, repaired.", type: .note, tags: ["x"])

        let (kept, dropped) = VerdictApplication.split(
            [.keep, .revise(repaired), .drop(reason: "junk")], candidates: [a, b, c])

        #expect(kept == [a, repaired])
        #expect(dropped.count == 1)
        #expect(dropped[0].fact == c)
        #expect(dropped[0].reason == "junk")
    }
}

@Suite("VerificationPrompt")
struct VerificationPromptTests {
    @Test("the prompt embeds the document, every numbered candidate, and the budget")
    func promptContainsEssentials() {
        let candidates = [
            ExtractedFact(title: "Coffee preference", content: "Prefers flat white.", type: .preference, tags: ["coffee"]),
            ExtractedFact(title: "Role", content: "Backend engineer.", type: .fact, tags: ["work"]),
        ]
        let prompt = VerificationPrompt.build(
            text: "THE-SOURCE-DOCUMENT",
            candidates: candidates,
            context: ExtractionContext(sourceName: "notes", relPath: "notes.md"))

        #expect(prompt.contains("THE-SOURCE-DOCUMENT"))          // grounding: verifier sees the source
        #expect(prompt.contains("0. title: Coffee preference"))
        #expect(prompt.contains("1. title: Role"))
        #expect(prompt.contains("every index 0-1"))
        #expect(prompt.contains("3-10 memories"))                // per-document budget
        #expect(prompt.contains("Do not use any tools"))
    }
}
