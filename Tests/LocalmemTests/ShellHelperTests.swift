import Foundation
import Testing
@testable import localmem

@Suite("ShellHelper")
struct ShellHelperTests {
    @Test("commandExists returns true for an absolute path to a real executable")
    func absolutePathExists() {
        #expect(ShellHelper.commandExists("/bin/sh"))
    }

    @Test("commandExists returns false for an absolute path to a missing file")
    func absolutePathMissing() {
        let bogus = "/tmp/definitely-missing-cmd-\(UUID().uuidString)"
        #expect(!ShellHelper.commandExists(bogus))
    }

    @Test("commandExists walks PATH and finds a bare command name")
    func bareNameOnPath() {
        // `sh` is on every POSIX system's PATH; the test runner inherits PATH.
        #expect(ShellHelper.commandExists("sh"))
    }

    @Test("commandExists returns false for a bare command name that isn't on PATH")
    func bareNameNotOnPath() {
        let bogus = "localmem-not-a-real-command-\(UUID().uuidString)"
        #expect(!ShellHelper.commandExists(bogus))
    }

    @Test("run captures stdout and reports exit code 0 for a successful command")
    func runCapturesSuccessfulOutput() throws {
        let result = try ShellHelper.run("/bin/echo", ["hello-shell"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello-shell")
    }

    @Test("runOrThrow throws ShellError when the command exits non-zero")
    func runOrThrowSurfacesFailure() {
        #expect(throws: ShellHelper.ShellError.self) {
            try ShellHelper.runOrThrow("/bin/sh", ["-c", "echo boom >&2; exit 7"])
        }
    }

    @Test("ShellError.commandFailed description includes the command, code, and stderr")
    func shellErrorDescription() {
        let err = ShellHelper.ShellError.commandFailed(
            command: "/bin/x",
            exitCode: 7,
            stderr: "bad input"
        )
        let s = String(describing: err)
        #expect(s.contains("/bin/x"))
        #expect(s.contains("7"))
        #expect(s.contains("bad input"))
    }

    @Test("run detaches stdin so a stdin-reading child gets EOF instead of hanging")
    func runDetachesStdin() throws {
        // `cat` with no args reads stdin to EOF. With stdin wired to /dev/null
        // it returns immediately instead of blocking — the setup-hang fix. If
        // stdin were the terminal, this would hang the test runner.
        let result = try ShellHelper.run("/bin/cat", [])
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("run terminates and throws .timedOut when a child overruns the timeout")
    func runTimesOutOnHang() {
        do {
            _ = try ShellHelper.run("/bin/sh", ["-c", "sleep 30"], timeout: 1)
            Issue.record("expected a timeout, but the command returned")
        } catch let error as ShellHelper.ShellError {
            guard case .timedOut = error else {
                Issue.record("expected .timedOut, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("ShellError.timedOut description names the command and the limit")
    func timedOutDescription() {
        let err = ShellHelper.ShellError.timedOut(command: "/bin/slow", seconds: 5)
        let s = String(describing: err)
        #expect(s.contains("/bin/slow"))
        #expect(s.contains("5"))
    }
}
