// Prints "<CGWindowID> <width> <height>" for an on-screen window owned by the
// named process. Used by scripts/screenshots.sh, which feeds the id to
// `screencapture -l`.
//
// Window ids are not otherwise reachable from a shell: AppleScript's `window id`
// is a different namespace, and `screencapture -w` only picks interactively.
//
// Windows are selected by size rather than title. `kCGWindowName` is only
// populated for processes holding Screen Recording permission, so title
// matching silently matches nothing when run from a context that lacks it —
// and the Settings window (420pt wide) has to be told apart from the main
// window (1100pt) either way.
//
// Usage: windowid.swift <owner> [min-width] [max-width]
import CoreGraphics
import Foundation

let ownerName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "localmem-app"
let minWidth = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 380 : 380
let maxWidth = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? .infinity : .infinity

guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("cannot list windows\n".utf8))
    exit(1)
}

for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == ownerName,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
    else { continue }
    // Skip tooltips, menus, and other small panels the app also owns.
    guard height > 280, width >= minWidth, width <= maxWidth else { continue }
    print("\(number) \(Int(width)) \(Int(height))")
    exit(0)
}

FileHandle.standardError.write(
    Data("no \(ownerName) window with width in [\(minWidth), \(maxWidth)]\n".utf8))
exit(2)
