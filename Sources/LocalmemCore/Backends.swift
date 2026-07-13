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

#if canImport(FoundationModels)
@available(macOS 26, *)
public struct AppleFoundationExtractor: FactExtractor {
    public init() {}

    public func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact] {
        let session = LanguageModelSession()
        let prompt = ExtractionPrompt.build(text: text, context: context)
        do {
            let response = try await session.respond(to: prompt)
            return FactParsing.parse(response.content)
        } catch {
            throw ExtractionError.failed(error.localizedDescription)
        }
    }
}

@available(macOS 26, *)
public struct AppleFoundationVerifier: FactVerifier {
    public init() {}

    public func verify(candidates: [ExtractedFact], against text: String,
                       context: ExtractionContext) async throws -> [FactVerdict] {
        let session = LanguageModelSession()
        let prompt = VerificationPrompt.build(text: text, candidates: candidates, context: context)
        let content: String
        do {
            content = try await session.respond(to: prompt).content
        } catch {
            throw ExtractionError.failed(error.localizedDescription)
        }
        guard let verdicts = VerdictParsing.parse(content, candidates: candidates) else {
            throw ExtractionError.invalidOutput("Verifier output did not cover every candidate exactly once.")
        }
        return verdicts
    }
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
