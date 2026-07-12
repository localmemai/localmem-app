import Foundation
import LocalmemCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Process runner

/// Runs a command through the user's login shell (`zsh -lc`) so PATH includes
/// node/nvm/homebrew, with a hard timeout. The prompt is passed via an
/// environment variable and referenced as "$LM_PROMPT" so its contents are never
/// interpreted as shell syntax (injection-safe).
enum ProcessRunner {
    struct Result: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var timedOut: Bool
    }

    private final class Box: @unchecked Sendable { var timedOut = false }

    static func runShell(_ command: String, env extra: [String: String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lc", command]
                var environment = ProcessInfo.processInfo.environment
                for (k, v) in extra { environment[k] = v }
                proc.environment = environment

                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

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
    static func commandExists(_ name: String) async -> Bool {
        let r = await runShell("command -v \(name) >/dev/null 2>&1", env: [:], timeout: 15)
        return r.exitCode == 0
    }
}

// MARK: - Agent CLI extractor

/// Delegates extraction to a configured CLI agent, driven headlessly by Localmem.
struct AgentCLIExtractor: FactExtractor {
    let agentID: String   // "claude-code" | "codex"

    func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact] {
        let prompt = ExtractionPrompt.build(text: text, context: context)
        let command: String
        // Imported file text is untrusted and embedded verbatim in the prompt, so
        // it can attempt prompt injection. Run the agent as a pure text→text call
        // with every tool channel hard-disabled — NOT relying on the advisory
        // "do not use tools" prompt line. Critically this strips the user's MCP
        // config (including the pre-authorized localmem tools), so a crafted
        // document cannot reach memory_store or any other pre-approved tool.
        switch agentID {
        case "claude-code":
            // --strict-mcp-config + an empty --mcp-config loads no MCP servers;
            // --disallowedTools "*" blocks the built-in tools.
            command = "claude -p \"$LM_PROMPT\" --output-format json"
                + " --disallowedTools \"*\" --strict-mcp-config --mcp-config '{\"mcpServers\":{}}'"
        case "codex":
            // Read-only sandbox blocks writes/exec; empty mcp_servers strips MCP.
            command = "codex exec --sandbox read-only -c mcp_servers='{}' \"$LM_PROMPT\""
        default:
            throw ExtractionError.unavailable("Unsupported agent: \(agentID)")
        }

        let result = await ProcessRunner.runShell(command, env: ["LM_PROMPT": prompt],
                                                  timeout: ConnectorLimits.extractionTimeout)
        if result.timedOut { throw ExtractionError.timedOut }
        guard result.exitCode == 0 else {
            let msg = result.stderr.isEmpty ? result.stdout : result.stderr
            throw ExtractionError.failed(Self.snippet(msg))
        }

        // Claude Code's --output-format json wraps the answer in an envelope.
        let answer: String
        if agentID == "claude-code", let unwrapped = Self.claudeResult(result.stdout) {
            answer = unwrapped
        } else {
            answer = result.stdout
        }
        return FactParsing.parse(answer)
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

// MARK: - Apple on-device extractor

#if canImport(FoundationModels)
@available(macOS 26, *)
struct AppleFoundationExtractor: FactExtractor {
    func extract(from text: String, context: ExtractionContext) async throws -> [ExtractedFact] {
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
#endif

// MARK: - Backend availability + selection

enum ConnectorBackends {
    /// CLI agents Localmem can drive headlessly: id → display name → command.
    static let cliAgents: [(id: String, name: String, command: String)] = [
        ("claude-code", "Claude Code", "claude"),
        ("codex", "Codex", "codex"),
    ]

    /// Whether Apple's on-device model is usable right now.
    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return true
            default: return false
            }
        }
        #endif
        return false
    }

    /// A short reason the on-device model isn't available (for the wizard).
    static var appleUnavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return ""
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence isn't turned on for this Mac."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading."
            case .unavailable(.deviceNotEligible):
                return "This Mac isn't eligible for Apple Intelligence."
            case .unavailable:
                return "The on-device model isn't available."
            }
        }
        return "Requires macOS 26 with Apple Intelligence."
        #else
        return "The on-device model isn't available on this build."
        #endif
    }

    /// The CLI agents from the catalog that are actually installed.
    static func availableAgents() async -> [(id: String, name: String)] {
        var out: [(id: String, name: String)] = []
        for agent in cliAgents {
            if await ProcessRunner.commandExists(agent.command) {
                out.append((agent.id, agent.name))
            }
        }
        return out
    }

    /// User-facing name for a backend (detail-pane badge, choice rows).
    static func displayName(for backend: ExtractionBackend) -> String {
        switch backend {
        case .apple:         return "On-device"
        case .agent(let id): return cliAgents.first { $0.id == id }?.name ?? id
        }
    }

    /// The extractor for a chosen backend.
    static func extractor(for backend: ExtractionBackend) -> FactExtractor {
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
}
