import Foundation
import Testing
@testable import localmem

@Suite("ProgressBar")
struct ProgressBarTests {
    @Test("isTerminal is false when stdout is redirected through the test runner")
    func isTerminalFalseUnderTests() {
        // This guard is what keeps the progress bar out of CI/log output.
        #expect(!ProgressBar.isTerminal)
    }

    @Test("draw / drawWithSpinner / clear are no-ops when stdout is not a TTY")
    func drawDoesNotCrashWhenNotTerminal() {
        // No stdout assertion — the guard short-circuits before any write.
        // The test just pins the no-crash contract that SetupCommand depends on.
        ProgressBar.draw(current: 1, total: 2, label: "x")
        ProgressBar.drawWithSpinner(current: 0, total: 0, label: "x", frame: 0)
        ProgressBar.clear()
    }

    @Test("spinnerFrames is the four-character ASCII rotation")
    func spinnerFramesContent() {
        #expect(ProgressBar.spinnerFrames == ["|", "/", "-", "\\"])
    }
}
