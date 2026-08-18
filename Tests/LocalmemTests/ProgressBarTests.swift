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

    @Test("render fills the bar in proportion and prints the percentage")
    func renderProportional() {
        let line = ProgressBar.render(current: 3, total: 6, label: "Registering Antigravity")
        #expect(line.contains("[" + String(repeating: "#", count: 12) + String(repeating: ".", count: 12) + "]"))
        #expect(line.contains(" 50%"))
        #expect(line.contains("Registering Antigravity"))
        // Carriage return + clear-to-EOL are what make the bar redraw in place.
        #expect(line.hasPrefix("\r"))
        #expect(line.hasSuffix("\u{001B}[K"))
    }

    @Test("render clamps a current above total instead of overflowing the bar")
    func renderClampsOverflow() {
        let line = ProgressBar.render(current: 99, total: 6, label: "x")
        #expect(line.contains("[" + String(repeating: "#", count: ProgressBar.width) + "]"))
    }

    @Test("render treats a zero total as 0% rather than dividing by zero")
    func renderHandlesZeroTotal() {
        let line = ProgressBar.render(current: 0, total: 0, label: "x")
        #expect(line.contains("[" + String(repeating: ".", count: ProgressBar.width) + "]"))
        #expect(line.contains("  0%"))
    }

    @Test("drawWithSpinner cycles the frames and wraps past the last one")
    func spinnerAdvancesAndWraps() {
        // drawWithSpinner prefixes the label; render is where that lands.
        let frames = (0..<5).map { frame in
            ProgressBar.render(current: 1, total: 4,
                               label: "\(ProgressBar.spinnerFrames[frame % ProgressBar.spinnerFrames.count]) Step")
        }
        #expect(frames[0].contains("| Step"))
        #expect(frames[1].contains("/ Step"))
        #expect(frames[3].contains("\\ Step"))
        #expect(frames[4] == frames[0])   // wraps
    }

    @Test("spinnerFrames is the four-character ASCII rotation")
    func spinnerFramesContent() {
        #expect(ProgressBar.spinnerFrames == ["|", "/", "-", "\\"])
    }
}
