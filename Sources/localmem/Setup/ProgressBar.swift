import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ProgressBar {
    static let width = 24

    /// True when stdout is a terminal — false when redirected to a file or pipe.
    /// We skip the progress bar entirely in non-TTY contexts so log files stay clean.
    static var isTerminal: Bool {
        isatty(FileHandle.standardOutput.fileDescriptor) != 0
    }

    /// Draws (or redraws) the progress bar in-place using CR + ANSI clear-to-end-of-line.
    /// Examples:
    ///   [#####...................]  20%  Registering Claude Code
    ///   [############............]  50%  Registering Antigravity
    static func draw(current: Int, total: Int, label: String) {
        guard isTerminal else { return }
        FileHandle.standardOutput.write(Data(render(current: current, total: total, label: label).utf8))
    }

    /// The bar's rendering, separated from the write so it stays exercisable
    /// off a TTY — under the test runner `draw` short-circuits before it would
    /// ever compute this.
    static func render(current: Int, total: Int, label: String) -> String {
        let filled = total > 0 ? min(current * width / total, width) : 0
        let empty = width - filled
        let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: empty)
        let percent = total > 0 ? current * 100 / total : 0
        return "\r[\(bar)] \(String(format: "%3d", percent))%  \(label)\u{001B}[K"
    }

    /// Erases the progress line and returns the cursor to its start.
    static func clear() {
        guard isTerminal else { return }
        FileHandle.standardOutput.write(Data("\r\u{001B}[K".utf8))
    }

    /// Pure-ASCII spinner frames — rotates while a long step is running so the
    /// user sees motion even when the bar itself is stuck at the same percentage.
    static let spinnerFrames: [Character] = ["|", "/", "-", "\\"]

    /// Draws the bar with a leading spinner character that advances per frame.
    static func drawWithSpinner(current: Int, total: Int, label: String, frame: Int) {
        guard isTerminal else { return }
        let spinner = spinnerFrames[frame % spinnerFrames.count]
        draw(current: current, total: total, label: "\(spinner) \(label)")
    }
}
