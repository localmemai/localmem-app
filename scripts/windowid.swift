// Prints the CGWindowID and bounds of the frontmost on-screen window owned by
// the process named on the command line. Used by scripts/screenshots.sh, which
// feeds the id to `screencapture -l`.
//
// Window ids are not otherwise reachable from the shell: AppleScript's `window
// id` is a different namespace, and `screencapture -w` only picks interactively.
import CoreGraphics
import Foundation

let ownerName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "localmem-app"

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
    // Skip the small helper/panel windows the app also owns.
    guard width > 400, height > 300 else { continue }
    print("\(number) \(Int(width)) \(Int(height))")
    exit(0)
}

FileHandle.standardError.write(Data("no window found for \(ownerName)\n".utf8))
exit(2)
