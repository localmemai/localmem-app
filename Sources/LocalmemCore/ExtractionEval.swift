import Foundation

// MARK: - Eval harness (docs/Technical_Design.md �10 (eval harness)
//
// Two prompts means two things to tune; without measurement, tuning is vibes.
// The harness scores extract-only vs extract+verify on a golden fixture set so
// the verifier's contribution is always visible. It runs manually (hidden
// `localmem eval-extraction` command) because it hits a real backend — too
// slow/flaky for CI. The deterministic pieces here (loading, matching,
// metrics) stay in the normal test suite.

/// One golden document + the memories a perfect pipeline would store from it.
public struct ExtractionFixture: Sendable {
    public let name: String
    public let text: String
    public let expected: [ExpectedMemory]

    public init(name: String, text: String, expected: [ExpectedMemory]) {
        self.name = name
        self.text = text
        self.expected = expected
    }
}

/// Expected memory, phrased canonically. Matching is by normalized content
/// similarity, not string equality — the model won't phrase things verbatim.
public struct ExpectedMemory: Decodable, Sendable {
    public let title: String?
    public let content: String

    public init(title: String? = nil, content: String) {
        self.title = title
        self.content = content
    }
}

/// Scores one run of the pipeline against one fixture's expected set.
public struct EvalMetrics: Sendable {
    public let expectedCount: Int
    public let actualCount: Int
    /// Stored facts that match no expected memory — the junk that got through.
    public let junkKept: Int
    /// Expected memories no stored fact matches — real facts that were lost.
    public let goodLost: Int
    /// Extra stored facts matching an already-matched expected memory.
    public let duplicates: Int

    public var junkKeptRate: Double { actualCount == 0 ? 0 : Double(junkKept) / Double(actualCount) }
    public var goodLostRate: Double { expectedCount == 0 ? 0 : Double(goodLost) / Double(expectedCount) }
    public var duplicateRate: Double { actualCount == 0 ? 0 : Double(duplicates) / Double(actualCount) }
}

public enum ExtractionEval {

    // MARK: Fixture loading

    /// Loads every `<name>.md` / `<name>.txt` in the directory that has a
    /// sibling `<name>.expected.json` (a JSON array of {title?, content}).
    public static func loadFixtures(from directory: URL) throws -> [ExtractionFixture] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        var fixtures: [ExtractionFixture] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where ["md", "txt"].contains(url.pathExtension.lowercased()) {
            let expectedURL = url.deletingPathExtension().appendingPathExtension("expected.json")
            guard FileManager.default.fileExists(atPath: expectedURL.path) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let expected = try JSONDecoder().decode(
                [ExpectedMemory].self, from: Data(contentsOf: expectedURL))
            fixtures.append(ExtractionFixture(
                name: url.deletingPathExtension().lastPathComponent,
                text: text, expected: expected))
        }
        return fixtures
    }

    // MARK: Scoring

    /// Greedy best-match assignment: each stored fact matches at most one
    /// expected memory (the most similar unmatched one above the threshold);
    /// a fact whose best match is already taken counts as a duplicate; a fact
    /// matching nothing counts as junk; an expected memory nobody matched
    /// counts as lost.
    public static func score(actual: [ExtractedFact], expected: [ExpectedMemory],
                             threshold: Double = 0.5) -> EvalMetrics {
        var matchedExpected = Set<Int>()
        var junk = 0, duplicates = 0

        for fact in actual {
            var bestIndex: Int? = nil
            var bestScore = 0.0
            for (index, exp) in expected.enumerated() {
                let s = similarity(fact.content, exp.content)
                if s > bestScore { bestScore = s; bestIndex = index }
            }
            guard let best = bestIndex, bestScore >= threshold else { junk += 1; continue }
            if matchedExpected.contains(best) {
                duplicates += 1
            } else {
                matchedExpected.insert(best)
            }
        }

        return EvalMetrics(
            expectedCount: expected.count,
            actualCount: actual.count,
            junkKept: junk,
            goodLost: expected.count - matchedExpected.count,
            duplicates: duplicates)
    }

    /// Token-set Jaccard over normalized words — order-insensitive, robust to
    /// rephrasing, deliberately simple so scores are explainable.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        if ta.isEmpty && tb.isEmpty { return 1 }
        let intersection = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })   // drop stopword-length noise ("a", "of", "is")
    }
}
