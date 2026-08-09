import Foundation

/// Deterministic text chunking for the on-device backend, whose model has a
/// hard 4,096-token context window (input + output combined) — a fraction of
/// what one imported file can hold. Both passes chunk the same text with the
/// same parameters, so Pass 2 can re-derive Pass 1's chunks and judge each
/// candidate against the chunk it came from instead of the whole document.
///
/// Pure string logic, no model dependency — fully unit-testable.
public enum TextChunking {
    /// Split `text` into chunks of at most `maxChars`, preferring paragraph
    /// boundaries, then line/sentence boundaries, then a hard character split
    /// for pathological unbroken runs. Never returns empty chunks; returns
    /// `[text]` unchanged when it already fits.
    public static func chunks(of text: String, maxChars: Int) -> [String] {
        precondition(maxChars > 0)
        guard text.count > maxChars else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [text]
        }

        var out: [String] = []
        var current = ""
        for piece in pieces(of: text, maxChars: maxChars) {
            if current.count + piece.count > maxChars, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += piece
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(current)
        }
        return out
    }

    /// Assign each candidate to the chunk that best supports it, by lexical
    /// overlap between the candidate's words and each chunk's words. Returns
    /// one array of candidate indices per chunk (same order as `chunks`).
    /// A candidate with no overlap anywhere falls back to the first chunk.
    public static func assign(candidates: [ExtractedFact], toChunks chunks: [String]) -> [[Int]] {
        guard !chunks.isEmpty else { return [] }
        var groups = [[Int]](repeating: [], count: chunks.count)
        let chunkWords = chunks.map { wordSet($0) }
        for (index, candidate) in candidates.enumerated() {
            let words = wordSet(candidate.title + " " + candidate.content)
            var best = 0, bestScore = -1
            for (chunkIndex, set) in chunkWords.enumerated() {
                let score = words.intersection(set).count
                if score > bestScore { best = chunkIndex; bestScore = score }
            }
            groups[best].append(index)
        }
        return groups
    }

    // MARK: - Internals

    /// Break text into paragraph-ish pieces, each individually ≤ maxChars.
    private static func pieces(of text: String, maxChars: Int) -> [String] {
        // Keep the separators attached so rejoining chunks loses nothing.
        var paragraphs: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            current += line + "\n"
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs.flatMap { paragraph -> [String] in
            guard paragraph.count > maxChars else { return [paragraph] }
            // Oversized paragraph: split by lines, hard-splitting any single
            // line that still exceeds the budget (e.g. minified text).
            return paragraph.split(separator: "\n", omittingEmptySubsequences: false)
                .flatMap { line -> [String] in
                    let line = String(line) + "\n"
                    guard line.count > maxChars else { return [line] }
                    return stride(from: 0, to: line.count, by: maxChars).map {
                        let start = line.index(line.startIndex, offsetBy: $0)
                        let end = line.index(start, offsetBy: maxChars, limitedBy: line.endIndex) ?? line.endIndex
                        return String(line[start..<end])
                    }
                }
        }
    }

    /// Lowercased alphanumeric words of 3+ characters — short words ("the",
    /// "is") carry no signal for chunk assignment.
    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })
    }
}
