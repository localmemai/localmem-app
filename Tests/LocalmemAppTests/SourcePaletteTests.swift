import Testing
import SwiftUI
@testable import localmem_app

/// `SourcePalette.color(for:)` is the single source of truth for the source-dot
/// hue rendered in every sidebar row and the detail metadata strip. Recognized
/// agent writers get a saturated hue; the literal user actor gets the accent
/// color; nil/empty (unknown provenance) returns nil so the view draws a hollow
/// ring; everything else falls back to grey. The mapping is referenced from two
/// places in the UI, so locking it down catches accidental palette drift.
@Suite("SourcePalette.color(for:)")
struct SourcePaletteTests {
    @Test func userActorMapsToAccentColor() {
        #expect(SourcePalette.color(for: "user") == .accentColor)
    }

    @Test func claudeCodeAndDesktopShareOrange() {
        #expect(SourcePalette.color(for: "claude-code") == .orange)
        #expect(SourcePalette.color(for: "claude-desktop") == .orange)
    }

    @Test func cursorMapsToPurple() {
        #expect(SourcePalette.color(for: "cursor") == .purple)
    }

    @Test func codexMapsToGreen() {
        #expect(SourcePalette.color(for: "codex") == .green)
    }

    @Test func antigravityAndClientShareePink() {
        #expect(SourcePalette.color(for: "antigravity") == .pink)
        #expect(SourcePalette.color(for: "antigravity-client") == .pink)
    }

    /// `nil` and the empty string both mean "we have no record of who wrote
    /// this." The view treats both as the hollow-ring case by getting back nil.
    @Test func unknownProvenanceReturnsNil() {
        #expect(SourcePalette.color(for: nil) == nil)
        #expect(SourcePalette.color(for: "") == nil)
    }

    @Test func unrecognizedSourceFallsBackToGrey() {
        #expect(SourcePalette.color(for: "some-future-client") == .gray)
        #expect(SourcePalette.color(for: "RANDOM-VALUE-123") == .gray)
    }
}
