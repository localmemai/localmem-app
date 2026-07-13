import Foundation

// MARK: - Pass 2 — Verify (strict curator)
//
// Extraction is a *generate* task (rewarded for output → over-extracts);
// judgment is a *reject* task. The verifier sees the source text plus every
// surviving candidate in ONE batched call and returns a per-candidate verdict.
// Nothing reaches the vault without passing verification.
// See docs/Extraction_Quality_Design.md.

/// Per-candidate verdict from the verify pass.
public enum FactVerdict: Sendable, Equatable {
    /// Store the candidate as-is.
    case keep
    /// The fact is true and worth keeping but badly shaped — store the
    /// verifier's repaired version instead. This is what stops verification
    /// from tanking recall: a good fact with a bad title is fixed, not lost.
    case revise(ExtractedFact)
    /// Reject. The reason is debug-logged (never persisted) — free tuning
    /// data for the prompts and the eval harness.
    case drop(reason: String)
}

/// One backend that judges a candidate set against its source text. Same
/// backend as extraction, always — availability was already checked for Pass 1.
public protocol FactVerifier: Sendable {
    /// Returns exactly one verdict per candidate, in candidate order.
    /// Implementations should throw `ExtractionError.invalidOutput` when the
    /// model's answer cannot be mapped 1:1 onto the candidates — the engine
    /// fails the file (`verify_invalid_output`, retriable) rather than store
    /// unverified facts.
    func verify(candidates: [ExtractedFact], against text: String,
                context: ExtractionContext) async throws -> [FactVerdict]
}

/// The shared verification instruction, so on-device and agent backends judge
/// by the same rubric.
public enum VerificationPrompt {
    public static func build(text: String, candidates: [ExtractedFact],
                             context: ExtractionContext) -> String {
        let numbered = candidates.enumerated().map { index, fact in
            """
            \(index). title: \(fact.title)
               content: \(fact.content)
               type: \(fact.type.rawValue) · tags: \(fact.tags.joined(separator: ", "))
            """
        }.joined(separator: "\n")

        return """
        You are a strict curator of a personal memory store, deciding what \
        deserves to be remembered for years. Below is a source document and a \
        numbered list of candidate memories another pass extracted from it. \
        Judge every candidate against the document.

        A candidate is stored ONLY if it passes ALL of these gates:
        - Grounded: directly supported by the text — no embellishment, no \
        inference beyond what the document states.
        - Durable: still useful in six months, without the document in hand.
        - Owner-relevant: about the vault owner or their immediate world — \
        not about an unrelated third party the document merely mentions.
        - Atomic & self-contained: exactly one fact, understandable standalone.
        - Non-transactional: not a line item, log entry, running balance, or \
        document metadata (headings, labels, signatures, page numbers).

        Budget: a typical document yields 3-10 memories. A genuinely dense \
        document may justify more, but every extra one must clearly pass every \
        gate — prefer dropping over padding.

        Verdicts:
        - "keep" — store as-is.
        - "revise" — the fact is true and worth keeping but badly shaped \
        (title, type, phrasing). Return the repaired fact. Do not introduce \
        information the candidate did not already carry.
        - "drop" — reject, with a one-line reason. Drop a near-duplicate of a \
        better candidate with a reason like "duplicate of #3".

        Return ONLY a JSON array (no prose, no markdown code fences) with \
        EXACTLY one entry per candidate, covering every index 0-\(candidates.count - 1):
        {"index": 0, "verdict": "keep"}
        {"index": 1, "verdict": "revise", "title": "...", "content": "...", "type": "fact|preference|decision|project|note", "tags": ["..."], "reason": "why it was reshaped"}
        {"index": 2, "verdict": "drop", "reason": "why"}

        Do not use any tools; answer directly.

        Source: \(context.sourceName) — \(context.relPath)

        DOCUMENT:
        \(text)

        CANDIDATES:
        \(numbered)
        """
    }
}

/// Applies a verdict set to its candidates: keep → as-is, revise → the
/// repaired fact, drop → excluded (returned with its reason so callers can
/// debug-log or print it — reasons are never persisted).
public enum VerdictApplication {
    public static func split(_ verdicts: [FactVerdict], candidates: [ExtractedFact])
        -> (kept: [ExtractedFact], dropped: [(fact: ExtractedFact, reason: String)]) {
        var kept: [ExtractedFact] = []
        var dropped: [(ExtractedFact, String)] = []
        for (candidate, verdict) in zip(candidates, verdicts) {
            switch verdict {
            case .keep:                 kept.append(candidate)
            case .revise(let repaired): kept.append(repaired)
            case .drop(let reason):     dropped.append((candidate, reason))
            }
        }
        return (kept, dropped)
    }
}

/// Tolerant parse of the verifier's answer — same approach as `FactParsing`
/// (strip fences, isolate the outer array, permissive fields) — followed by a
/// strict completeness check: every candidate index exactly once, none out of
/// range. Partial coverage means unverified facts, so the whole parse fails
/// (`nil`) and the engine marks the file `verify_invalid_output`.
public enum VerdictParsing {
    private struct RawVerdict: Decodable {
        var index: Int?
        var verdict: String?
        var title: String?
        var content: String?
        var type: String?
        var tags: [String]?
        var reason: String?
    }

    /// Returns verdicts in candidate order, or nil when the answer cannot be
    /// mapped 1:1 onto the candidates.
    public static func parse(_ raw: String, candidates: [ExtractedFact]) -> [FactVerdict]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                       .replacingOccurrences(of: "```", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"),
              start <= end,
              let data = String(text[start...end]).data(using: .utf8),
              let rows = try? JSONDecoder().decode([RawVerdict].self, from: data)
        else { return nil }

        var byIndex: [Int: FactVerdict] = [:]
        for row in rows {
            guard let index = row.index, candidates.indices.contains(index),
                  byIndex[index] == nil,
                  let verdict = verdict(from: row, original: candidates[index])
            else { return nil }
            byIndex[index] = verdict
        }
        guard byIndex.count == candidates.count else { return nil }
        return candidates.indices.map { byIndex[$0]! }
    }

    private static func verdict(from row: RawVerdict, original: ExtractedFact) -> FactVerdict? {
        switch row.verdict?.lowercased() {
        case "keep":
            return .keep
        case "drop":
            return .drop(reason: row.reason ?? "unspecified")
        case "revise":
            // Field-wise fallback to the original: a revise that only fixes
            // the title shouldn't lose the content (and vice versa).
            let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = row.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = row.type.flatMap { MemoryType(rawValue: $0.lowercased()) }
            let tags = row.tags.map { $0.map { $0.lowercased() }.filter { !$0.isEmpty } }
            return .revise(ExtractedFact(
                title: title?.isEmpty == false ? title! : original.title,
                content: content?.isEmpty == false ? content! : original.content,
                type: type ?? original.type,
                tags: tags ?? original.tags
            ))
        default:
            return nil
        }
    }
}
