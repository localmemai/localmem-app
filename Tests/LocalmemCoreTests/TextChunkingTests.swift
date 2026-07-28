import Foundation
import Testing
@testable import LocalmemCore

@Suite("TextChunking")
struct TextChunkingTests {
    private func fact(_ title: String, _ content: String) -> ExtractedFact {
        ExtractedFact(title: title, content: content, type: .fact, tags: [])
    }

    @Test("Text under the budget comes back as a single chunk, unchanged")
    func underBudgetIsOneChunk() {
        let text = "A short note.\n\nWith two paragraphs."
        #expect(TextChunking.chunks(of: text, maxChars: 1000) == [text])
    }

    @Test("Whitespace-only text yields no chunks")
    func whitespaceYieldsNothing() {
        #expect(TextChunking.chunks(of: "  \n\n  ", maxChars: 100).isEmpty)
    }

    @Test("Every chunk respects the budget and no text is lost")
    func chunksRespectBudgetAndPreserveText() {
        let paragraphs = (1...40).map { "Paragraph \($0): " + String(repeating: "word ", count: 30) }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = TextChunking.chunks(of: text, maxChars: 800)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 800 })
        // Rejoining loses nothing but the trailing newline normalization.
        let rejoined = chunks.joined()
        #expect(rejoined.replacingOccurrences(of: "\n", with: "") ==
                text.replacingOccurrences(of: "\n", with: ""))
    }

    @Test("Chunking prefers paragraph boundaries")
    func splitsOnParagraphs() {
        let a = String(repeating: "aaaa ", count: 30)   // 150 chars
        let b = String(repeating: "bbbb ", count: 30)
        let chunks = TextChunking.chunks(of: a + "\n\n" + b, maxChars: 200)
        #expect(chunks.count == 2)
        #expect(chunks[0].contains("aaaa") && !chunks[0].contains("bbbb"))
        #expect(chunks[1].contains("bbbb") && !chunks[1].contains("aaaa"))
    }

    @Test("A single unbroken line longer than the budget is hard-split")
    func hardSplitsUnbrokenRuns() {
        let text = String(repeating: "x", count: 2500)
        let chunks = TextChunking.chunks(of: text, maxChars: 1000)
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.count <= 1000 })
        #expect(chunks.joined().filter { $0 == "x" }.count == 2500)
    }

    @Test("Chunking is deterministic — both passes derive identical chunks")
    func deterministic() {
        let text = (1...50).map { "Line \($0) with some words in it." }.joined(separator: "\n")
        let first = TextChunking.chunks(of: text, maxChars: 300)
        let second = TextChunking.chunks(of: text, maxChars: 300)
        #expect(first == second)
    }

    @Test("Candidates are assigned to the chunk that supports them")
    func assignsByLexicalOverlap() {
        let chunks = [
            "Vidit switched the team's issue tracking to Linear last week after evaluating options.\n",
            "The quarterly budget review moved to Thursdays. Finance prefers morning meetings.\n",
        ]
        let candidates = [
            fact("Budget review day", "The quarterly budget review happens on Thursdays."),
            fact("Linear adoption", "Moved the team's issue tracking to Linear."),
        ]
        let groups = TextChunking.assign(candidates: candidates, toChunks: chunks)
        #expect(groups == [[1], [0]])
    }

    @Test("A candidate with no overlap anywhere falls back to the first chunk")
    func noOverlapFallsBackToFirst() {
        let groups = TextChunking.assign(
            candidates: [fact("Zzz", "Qqq www eee.")],
            toChunks: ["alpha beta gamma\n", "delta epsilon zeta\n"])
        #expect(groups == [[0], []])
    }

    @Test("Assignment covers every candidate exactly once")
    func assignmentIsAPartition() {
        let chunks = (0..<5).map { "chunk number \($0) talks about topic\($0) extensively.\n" }
        let candidates = (0..<13).map { fact("Fact \($0)", "Concerns topic\($0 % 5) in detail.") }
        let groups = TextChunking.assign(candidates: candidates, toChunks: chunks)
        let all = groups.flatMap { $0 }.sorted()
        #expect(all == Array(0..<13))
    }
}
