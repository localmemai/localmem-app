import SwiftUI
import AppKit

/// Renders an agent's real brand mark (bundled under Resources/AgentIcons),
/// falling back to the SF Symbol placeholder when no brand asset matches.
///
/// Brand PNGs are multicolor, so they render as-is — callers should NOT wrap
/// this in `.foregroundStyle(...)` expecting a tint; the SF Symbol fallback is
/// what picks up the surrounding tint.
struct AgentIcon: View {
    let agentID: String
    /// SF Symbol used when there's no brand asset for this agent.
    let symbol: String
    var size: CGFloat = 22

    var body: some View {
        if let image = Self.brandImage(for: agentID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.82))
                .frame(width: size, height: size)
        }
    }

    /// Maps an agent id to its brand asset base name. Both Claude surfaces share
    /// one mark; unknown ids (e.g. the "canonical" instruction row) return nil so
    /// the SF Symbol fallback is used.
    static func assetName(for agentID: String) -> String? {
        switch agentID {
        case "claude-code", "claude-desktop": return "claude"
        case "cursor":                        return "cursor"
        case "codex":                         return "codex"
        case "antigravity-client", "antigravity": return "antigravity"
        default: return nil
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func brandImage(for agentID: String) -> NSImage? {
        guard let name = assetName(for: agentID) else { return nil }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.module.url(
                forResource: name, withExtension: "png", subdirectory: "AgentIcons"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        cache[name] = image
        return image
    }
}
