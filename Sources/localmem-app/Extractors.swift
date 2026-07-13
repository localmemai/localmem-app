import Foundation
import LocalmemCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// The backend implementations (ProcessRunner, AgentCLIExtractor/Verifier,
// AppleFoundation*) live in LocalmemCore so the app, the CLI, and the eval
// harness share one code path. This file keeps only the UI-facing catalog:
// availability checks and display names for the wizard and detail pane.

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
        ExtractionBackends.extractor(for: backend)
    }

    /// The verifier for the same backend — extract and verify always share one.
    static func verifier(for backend: ExtractionBackend) -> FactVerifier {
        ExtractionBackends.verifier(for: backend)
    }
}
