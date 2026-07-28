import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Process runner

/// Runs a command through the user's login shell (`zsh -lc`) so PATH includes
/// node/nvm/homebrew, with a hard timeout. The prompt is streamed over stdin —
/// never shell syntax (injection-safe), and never subject to the ~1 MB kernel
/// arg+env limit that passing it as an argument or environment variable would
/// hit (a file near the 1M-char text cap can exceed 4 MB of UTF-8).
public enum ProcessRunner {
    public struct Result: Sendable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
        public var timedOut: Bool
    }

    private final class Box: @unchecked Sendable { var timedOut = false }

    public static func runShell(_ command: String, stdin: String? = nil,
                                timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lc", command]

                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                // Without input the child gets EOF immediately (a CLI waiting
                // on a TTY would otherwise hang until the watchdog kills it).
                let inPipe = Pipe()
                proc.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: Result(stdout: "", stderr: error.localizedDescription, exitCode: -1, timedOut: false))
                    return
                }

                // Feed stdin off-thread: a prompt larger than the pipe buffer
                // (~64 KB) would deadlock if written before waiting.
                if let stdin {
                    DispatchQueue.global().async {
                        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                        try? inPipe.fileHandleForWriting.close()
                    }
                }

                let box = Box()
                let watchdog = DispatchWorkItem {
                    if proc.isRunning { box.timedOut = true; proc.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                proc.waitUntilExit()
                watchdog.cancel()
                group.wait()

                cont.resume(returning: Result(
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus,
                    timedOut: box.timedOut))
            }
        }
    }

    /// Whether a command is resolvable on the login-shell PATH.
    public static func commandExists(_ name: String) async -> Bool {
        let r = await runShell("command -v \(name) >/dev/null 2>&1", timeout: 15)
        return r.exitCode == 0
    }
}

// MARK: - Agent CLI invocation (shared by extract + verify)

/// One locked-down text→text call to a configured CLI agent. Both passes use
/// exactly the same hardening: imported file text is untrusted and embedded
/// verbatim in the prompt, so it can attempt prompt injection. The agent runs
/// with every tool channel hard-disabled — NOT relying on the advisory "do not
/// use tools" prompt line. Critically this strips the user's MCP config
/// (including the pre-authorized localmem tools), so a crafted document cannot
/// reach memory_store or any other pre-approved tool. The prompt itself
/// arrives over stdin: shell-inert and immune to the kernel arg+env size limit
/// a near-cap file would blow through.
enum AgentCLIInvocation {
    static func answer(agentID: String, prompt: String) async throws -> String {
        let command: String
        switch agentID {
        case "claude-code":
            // --strict-mcp-config + an empty --mcp-config loads no MCP servers;
            // --disallowedTools "*" blocks the built-in tools. With no prompt
            // argument, `claude -p` reads the prompt from stdin.
            command = "claude -p --output-format json"
                + " --disallowedTools \"*\" --strict-mcp-config --mcp-config '{\"mcpServers\":{}}'"
        case "codex":
            // Read-only sandbox blocks writes/exec; empty mcp_servers strips
            // MCP. `-` reads the prompt from stdin.
            command = "codex exec --sandbox read-only -c mcp_servers='{}' -"
        default:
            throw ExtractionError.unavailable("Unsupported agent: \(agentID)")
        }

        let result = await ProcessRunner.runShell(command, stdin: prompt,
                                                  timeout: ConnectorLimits.extractionTimeout)
        if result.timedOut { throw ExtractionError.timedOut }
        guard result.exitCode == 0 else {
            let msg = result.stderr.isEmpty ? result.stdout : result.stderr
            throw ExtractionError.failed(snippet(msg))
        }

        // Claude Code's --output-format json wraps the answer in an envelope.
        if agentID == "claude-code", let unwrapped = claudeResult(result.stdout) {
            return unwrapped
        }
        return result.stdout
    }

    private struct ClaudeEnvelope: Decodable { var result: String?; var is_error: Bool? }

    private static func claudeResult(_ stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let env = try? JSONDecoder().decode(ClaudeEnvelope.self, from: data) else { return nil }
        if env.is_error == true { return nil }
        return env.result
    }

    private static func snippet(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }
}

// MARK: - Agent CLI backends

/// Delegates Pass-1 extraction to a configured CLI agent, driven headlessly.
public struct AgentCLIExtractor: FactExtractor {
    public let agentID: String   // "claude-code" | "codex"

    public init(agentID: String) { self.agentID = agentID }

    public func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact] {
        let prompt = ExtractionPrompt.build(text: text, context: context)
        let answer = try await AgentCLIInvocation.answer(agentID: agentID, prompt: prompt)
        return FactParsing.parse(answer)
    }
}

/// Delegates Pass-2 verification to the same CLI agent. Whole-file verification
/// (no chunking needed at agent context sizes); one batched call per file.
public struct AgentCLIVerifier: FactVerifier {
    public let agentID: String

    public init(agentID: String) { self.agentID = agentID }

    public func verify(candidates: [ExtractedFact], against text: String,
                       context: ExtractionContext) async throws -> [FactVerdict] {
        let prompt = VerificationPrompt.build(text: text, candidates: candidates, context: context)
        let answer = try await AgentCLIInvocation.answer(agentID: agentID, prompt: prompt)
        guard let verdicts = VerdictParsing.parse(answer, candidates: candidates) else {
            throw ExtractionError.invalidOutput("Verifier output did not cover every candidate exactly once.")
        }
        return verdicts
    }
}

// MARK: - Apple on-device backends

/// Sizing for the on-device model, whose context window is 4,096 tokens for
/// input AND output combined (measured; the framework reports the same limit
/// in `exceededContextWindowSize` errors). Chunks leave headroom for the
/// rubric, the injected response schema, the candidate list, and the answer.
public enum AppleModelLimits {
    public static let chunkChars = 6_000
    public static let maxCandidatesPerCall = 12
    /// How many times an over-budget call may halve its chunk before giving
    /// up — 2 halvings put even token-dense text (~1 char/token) in budget.
    static let maxSplitDepth = 2
}

#if canImport(FoundationModels)

/// Guided-generation shapes: constrained decoding guarantees well-formed
/// output, so the malformed-JSON failure mode of the free-text path (#20)
/// cannot occur. Types are strings validated in code — `MemoryType` fallback
/// mirrors `FactParsing`.
@available(macOS 26, *)
@Generable
struct GeneratedFact {
    @Guide(description: "Short noun phrase naming the fact, not 'Label: value'.")
    var title: String
    @Guide(description: "One full, self-contained sentence, third person, present tense.")
    var content: String
    @Guide(description: "One of: fact, preference, decision, project, note.")
    var type: String
    @Guide(description: "2-4 lowercase tags.")
    var tags: [String]

    var asExtractedFact: ExtractedFact {
        ExtractedFact(
            title: title, content: content,
            type: MemoryType(rawValue: type.lowercased()) ?? .note,
            tags: tags)
    }
}

@available(macOS 26, *)
@Generable
struct GeneratedVerdict {
    @Guide(description: "The candidate's index from the CANDIDATES list.")
    var index: Int
    @Guide(description: "One of: keep, revise, drop.")
    var verdict: String
    @Guide(description: "For revise or drop: a one-line reason. Empty for keep.")
    var reason: String
    @Guide(description: "For revise only: the repaired fact.")
    var revision: GeneratedFact?
}

/// Pass 1 on the on-device model. The document is processed in chunks sized
/// to the model's context window; a chunk that still overflows (token-dense
/// text) is halved and retried.
@available(macOS 26, *)
public struct AppleFoundationExtractor: FactExtractor {
    public init() {}

    public func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        for chunk in TextChunking.chunks(of: text, maxChars: AppleModelLimits.chunkChars) {
            out += try await Self.extract(chunk: chunk, context: context, depth: 0)
        }
        return out
    }

    private static func extract(chunk: String, context: ExtractionContext,
                                depth: Int) async throws -> [ExtractedFact] {
        let prompt = ExtractionPrompt.guided(text: chunk, context: context)
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: [GeneratedFact].self)
            return response.content.map(\.asExtractedFact)
        } catch {
            guard shouldSplit(error), depth < AppleModelLimits.maxSplitDepth else {
                throw ExtractionError.failed(describeAppleError(error))
            }
            var out: [ExtractedFact] = []
            for half in TextChunking.chunks(of: chunk, maxChars: max(1, chunk.count / 2)) {
                out += try await extract(chunk: half, context: context, depth: depth + 1)
            }
            return out
        }
    }
}

/// Pass 2 on the on-device model. The whole document cannot fit next to the
/// rubric and candidate list, so the text is re-chunked with the SAME
/// parameters as Pass 1 and each candidate is judged against the chunk that best
/// supports it (lexical overlap — candidates are near-verbatim derivatives of
/// their source chunk).
@available(macOS 26, *)
public struct AppleFoundationVerifier: FactVerifier {
    public init() {}

    public func verify(candidates: [ExtractedFact], against text: String,
                       context: ExtractionContext) async throws -> [FactVerdict] {
        let chunks = TextChunking.chunks(of: text, maxChars: AppleModelLimits.chunkChars)
        guard !chunks.isEmpty else {
            throw ExtractionError.invalidOutput("No text to verify candidates against.")
        }

        var verdicts = [FactVerdict?](repeating: nil, count: candidates.count)
        for (chunkIndex, group) in TextChunking.assign(candidates: candidates, toChunks: chunks).enumerated() {
            var batch: [Int] = []
            for index in group {
                batch.append(index)
                if batch.count == AppleModelLimits.maxCandidatesPerCall {
                    try await Self.verify(batch: batch, from: candidates, against: chunks[chunkIndex],
                                          context: context, into: &verdicts)
                    batch = []
                }
            }
            if !batch.isEmpty {
                try await Self.verify(batch: batch, from: candidates, against: chunks[chunkIndex],
                                      context: context, into: &verdicts)
            }
        }

        return try verdicts.map {
            guard let verdict = $0 else {
                throw ExtractionError.invalidOutput("Verifier output did not cover every candidate exactly once.")
            }
            return verdict
        }
    }

    /// One guided call: judge `batch` (indices into `candidates`) against one
    /// chunk, writing results into `verdicts` at their original positions.
    ///
    /// Guided generation guarantees well-formed rows but not index bookkeeping
    /// — the small model sometimes skips, duplicates, or misnumbers a
    /// candidate. Rather than failing the file, any candidate the batched
    /// call did not cover cleanly is re-judged alone: a single-candidate call
    /// has no indices to get wrong, so coverage is guaranteed by construction.
    private static func verify(batch: [Int], from candidates: [ExtractedFact], against chunk: String,
                               context: ExtractionContext, into verdicts: inout [FactVerdict?]) async throws {
        let subset = batch.map { candidates[$0] }
        let prompt = VerificationPrompt.guided(text: chunk, candidates: subset, context: context)
        var seen = Set<Int>()
        do {
            let session = LanguageModelSession()
            let rows = try await session.respond(to: prompt, generating: [GeneratedVerdict].self).content
            for row in rows where subset.indices.contains(row.index) && !seen.contains(row.index) {
                seen.insert(row.index)
                verdicts[batch[row.index]] = verdict(from: row, candidate: subset[row.index])
            }
        } catch {
            throw ExtractionError.failed(describeAppleError(error))
        }

        for (local, global) in batch.enumerated() where !seen.contains(local) {
            verdicts[global] = try await verifyAlone(candidates[global], against: chunk, context: context)
        }
    }

    /// Repair path: one candidate, one call, the row's index ignored.
    private static func verifyAlone(_ candidate: ExtractedFact, against chunk: String,
                                    context: ExtractionContext) async throws -> FactVerdict {
        let prompt = VerificationPrompt.guided(text: chunk, candidates: [candidate], context: context)
        do {
            let session = LanguageModelSession()
            let row = try await session.respond(to: prompt, generating: GeneratedVerdict.self).content
            return verdict(from: row, candidate: candidate)
        } catch {
            throw ExtractionError.failed(describeAppleError(error))
        }
    }

    private static func verdict(from row: GeneratedVerdict, candidate: ExtractedFact) -> FactVerdict {
        switch row.verdict.lowercased() {
        case "revise":
            // A revise without a usable revision still means "worth keeping".
            guard let revision = row.revision,
                  !revision.title.isEmpty, !revision.content.isEmpty else { return .keep }
            return .revise(revision.asExtractedFact)
        case "drop":
            return .drop(reason: row.reason.isEmpty ? "dropped by verifier" : row.reason)
        default:
            return .keep
        }
    }
}

/// Human-readable message for FoundationModels errors — the framework's
/// `localizedDescription` is often just the enum case name.
@available(macOS 26, *)
private func describeAppleError(_ error: Error) -> String {
    if let e = error as? LanguageModelSession.GenerationError {
        switch e {
        case .exceededContextWindowSize:
            return "The document section was too large for the on-device model's context window."
        case .guardrailViolation:
            return "The on-device model's safety guardrails declined this content. Try a CLI agent backend for this file."
        default:
            return String(describing: e)
        }
    }
    return error.localizedDescription
}

/// Whether an error is the context-window overflow that a smaller chunk fixes.
@available(macOS 26, *)
private func shouldSplit(_ error: Error) -> Bool {
    if let e = error as? LanguageModelSession.GenerationError,
       case .exceededContextWindowSize = e { return true }
    return false
}
#endif

// MARK: - Backend ladder

/// Extractor + verifier selection for a chosen backend. Same backend for both
/// passes, permanently (docs/Technical_Design.md section 10, resolved questions).
public enum ExtractionBackends {
    public static func extractor(for backend: ExtractionBackend) -> FactExtractor {
        switch backend {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return AppleFoundationExtractor() }
            #endif
            return AgentCLIExtractor(agentID: "claude-code")   // unreachable if gated correctly
        case .agent(let id):
            return AgentCLIExtractor(agentID: id)
        }
    }

    public static func verifier(for backend: ExtractionBackend) -> FactVerifier {
        switch backend {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return AppleFoundationVerifier() }
            #endif
            return AgentCLIVerifier(agentID: "claude-code")    // unreachable if gated correctly
        case .agent(let id):
            return AgentCLIVerifier(agentID: id)
        }
    }
}
