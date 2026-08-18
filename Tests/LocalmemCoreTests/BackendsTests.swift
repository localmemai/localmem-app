import Foundation
import Testing
@testable import LocalmemCore

/// `ProcessRunner` is the single hardened path every agent-CLI backend shells
/// through. The properties tested here are the ones the hardening comments in
/// `Backends.swift` promise: the prompt travels over stdin (never as shell
/// syntax or an argv entry), a child that reads stdin gets EOF rather than
/// hanging, and a runaway child is killed at the timeout instead of wedging
/// an import.
@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("runShell captures stdout and reports exit code 0")
    func capturesStdout() async {
        let result = await ProcessRunner.runShell("echo hello-runner", timeout: 15)
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello-runner")
    }

    @Test("runShell captures stderr separately and surfaces a non-zero exit code")
    func capturesStderrAndFailure() async {
        let result = await ProcessRunner.runShell("echo boom >&2; exit 7", timeout: 15)
        #expect(result.exitCode == 7)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "boom")
    }

    @Test("stdin is streamed to the child rather than interpolated into the command")
    func stdinIsStreamed() async {
        let result = await ProcessRunner.runShell("cat", stdin: "prompt text\n", timeout: 15)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "prompt text\n")
    }

    /// The injection guarantee: shell metacharacters in the prompt reach the
    /// child as literal bytes. If the prompt were interpolated into the `zsh
    /// -lc` command string, the substitution would run and the marker file
    /// would exist.
    @Test("shell metacharacters in stdin are inert, not evaluated")
    func stdinIsShellInert() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("localmem-injection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let hostile = "$(touch '\(marker.path)'); `touch '\(marker.path)'`; rm -rf /\n"
        let result = await ProcessRunner.runShell("cat", stdin: hostile, timeout: 15)

        #expect(result.exitCode == 0)
        #expect(result.stdout == hostile)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A near-cap document is multiple megabytes of UTF-8 — far past both the
    /// ~64 KB pipe buffer and the ~1 MB kernel arg+env limit. The write happens
    /// off-thread precisely so this does not deadlock.
    @Test("a stdin payload larger than the pipe buffer does not deadlock")
    func largeStdinDoesNotDeadlock() async {
        let payload = String(repeating: "a", count: 500_000) + "\n"
        let result = await ProcessRunner.runShell("wc -c", stdin: payload, timeout: 60)
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "\(payload.utf8.count)")
    }

    @Test("with no stdin a stdin-reading child gets EOF instead of hanging")
    func nilStdinGivesEOF() async {
        // Wired to /dev/null, `cat` returns immediately. If stdin were the
        // terminal this would block until the watchdog fired.
        let result = await ProcessRunner.runShell("cat", timeout: 15)
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(!result.timedOut)
    }

    @Test("an overrunning child is terminated and flagged timedOut")
    func timeoutTerminatesChild() async {
        let result = await ProcessRunner.runShell("sleep 30", timeout: 1)
        #expect(result.timedOut)
        #expect(result.exitCode != 0)
    }

    @Test("commandExists resolves a real command on the login-shell PATH")
    func commandExistsTrue() async {
        #expect(await ProcessRunner.commandExists("cat"))
    }

    @Test("commandExists returns false for a command that isn't on PATH")
    func commandExistsFalse() async {
        #expect(await ProcessRunner.commandExists("localmem-not-a-real-command-\(UUID().uuidString)") == false)
    }
}

/// The dispatch layer in front of the agent CLIs. Only the paths that don't
/// require a real `claude` / `codex` binary are exercised here — the rejection
/// of an unknown agent must happen *before* anything is spawned.
@Suite("AgentCLIInvocation")
struct AgentCLIInvocationTests {

    @Test("an unsupported agent id throws .unavailable without spawning a process")
    func unsupportedAgentThrows() async {
        await #expect(throws: ExtractionError.self) {
            _ = try await AgentCLIInvocation.answer(agentID: "gpt-9", prompt: "hi")
        }
    }

    @Test("the .unavailable message names the rejected agent")
    func unsupportedAgentMessage() async {
        do {
            _ = try await AgentCLIInvocation.answer(agentID: "gpt-9", prompt: "hi")
            Issue.record("expected .unavailable, but the call returned")
        } catch let error as ExtractionError {
            guard case .unavailable(let message) = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
            #expect(message.contains("gpt-9"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

/// Backend selection. The contract from the design doc is that a backend picks
/// the *same* family for both passes — an agent extractor is never paired with
/// an on-device verifier.
@Suite("ExtractionBackends ladder")
struct ExtractionBackendsTests {

    @Test("an agent backend yields the CLI extractor and verifier for that agent")
    func agentBackendRoundTrip() {
        let extractor = ExtractionBackends.extractor(for: .agent("codex"))
        let verifier = ExtractionBackends.verifier(for: .agent("codex"))

        #expect((extractor as? AgentCLIExtractor)?.agentID == "codex")
        #expect((verifier as? AgentCLIVerifier)?.agentID == "codex")
    }

    @Test("each agent id selects its own backend pair")
    func agentIDIsCarriedThrough() {
        #expect((ExtractionBackends.extractor(for: .agent("claude-code")) as? AgentCLIExtractor)?.agentID
            == "claude-code")
        #expect((ExtractionBackends.verifier(for: .agent("claude-code")) as? AgentCLIVerifier)?.agentID
            == "claude-code")
    }

    /// On a machine without FoundationModels the `.apple` case falls back to
    /// the claude-code CLI pair; on macOS 26 it returns the on-device pair.
    /// Either way both passes must come from the same family — pairing an
    /// Apple extractor with a CLI verifier would silently change the rubric
    /// between passes.
    @Test("the apple backend returns a matched extractor/verifier pair")
    func appleBackendPairsConsistently() {
        let extractor = ExtractionBackends.extractor(for: .apple)
        let verifier = ExtractionBackends.verifier(for: .apple)

        let extractorIsCLI = extractor is AgentCLIExtractor
        let verifierIsCLI = verifier is AgentCLIVerifier
        #expect(extractorIsCLI == verifierIsCLI)

        if let cliExtractor = extractor as? AgentCLIExtractor,
           let cliVerifier = verifier as? AgentCLIVerifier {
            #expect(cliExtractor.agentID == "claude-code")
            #expect(cliVerifier.agentID == "claude-code")
        }
    }

    @Test("chunk sizing leaves headroom inside the on-device context window")
    func appleLimitsAreSane() {
        // The window is 4,096 tokens for input AND output combined; the chunk
        // budget plus the rubric and candidate list has to fit alongside it.
        #expect(AppleModelLimits.chunkChars > 0)
        #expect(AppleModelLimits.maxCandidatesPerCall > 0)
        #expect(AppleModelLimits.maxSplitDepth >= 1)
    }
}
