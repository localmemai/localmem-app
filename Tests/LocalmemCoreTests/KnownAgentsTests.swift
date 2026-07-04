import Foundation
import Testing
@testable import LocalmemCore

/// `KnownAgents.all` is the cross-cutting catalog the GUI's Agents grid, the
/// access-rules matrix columns, and (eventually) per-memory exclusions all
/// iterate. The mapping is small and static, but it ships as a public API in
/// LocalmemCore — locking down the basic invariants catches accidental drift.
@Suite("KnownAgents")
struct KnownAgentsTests {

    @Test("catalog ships the five recognized clients")
    func catalogIsNonEmpty() {
        let ids = KnownAgents.all.map(\.id)
        #expect(ids.count == 5)
        // Spot-check the ones registrars write to disk so a rename in one
        // place breaks this test rather than silently desyncing the UI.
        #expect(ids.contains("claude-code"))
        #expect(ids.contains("claude-desktop"))
        #expect(ids.contains("cursor"))
        #expect(ids.contains("codex"))
        #expect(ids.contains("antigravity-client"))
    }

    @Test("ids are unique — catalog cannot list the same agent twice")
    func idsAreUnique() {
        let ids = KnownAgents.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("display names are non-empty and distinct")
    func displayNamesArePresentAndUnique() {
        let names = KnownAgents.all.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test("ids are lowercase kebab-case — they double as activity actor_id keys")
    func idsAreLowercaseKebab() {
        for agent in KnownAgents.all {
            // The activity table stores `actor_id` verbatim; if KnownAgents
            // ever drifts to mixed case or whitespace, the equality checks
            // that drive per-agent reads/writes counts silently break.
            #expect(agent.id == agent.id.lowercased(),
                    "\(agent.id) must be lowercase")
            #expect(!agent.id.contains(" "),
                    "\(agent.id) must not contain whitespace")
        }
    }

    @Test("every entry has a non-empty SF Symbol name")
    func symbolsArePresent() {
        for agent in KnownAgents.all {
            #expect(!agent.symbol.isEmpty,
                    "\(agent.id) must declare an SF Symbol")
        }
    }
}
