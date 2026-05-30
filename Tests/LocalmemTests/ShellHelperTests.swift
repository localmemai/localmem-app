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
}
