import Testing
import Foundation
@testable import LocalmemCore

@Suite struct SemVerComparerTests {
    @Test func testSameVersion() {
        #expect(SemVerComparer.compare("1.0.1", "1.0.1") == .orderedSame)
        #expect(SemVerComparer.compare("v1.0.1", "1.0.1") == .orderedSame)
        #expect(SemVerComparer.compare("V1.0.1", "v1.0.1") == .orderedSame)
    }

    @Test func testMajorMinorPatchComparison() {
        #expect(SemVerComparer.compare("1.1.0", "1.0.1") == .orderedDescending)
        #expect(SemVerComparer.compare("1.0.0", "1.0.1") == .orderedAscending)
        #expect(SemVerComparer.compare("2.0.0", "1.99.99") == .orderedDescending)
        #expect(SemVerComparer.compare("1.10.0", "1.9.0") == .orderedDescending)
    }

    @Test func testDifferentLengths() {
        #expect(SemVerComparer.compare("1.0", "1.0.0") == .orderedSame)
        #expect(SemVerComparer.compare("1.0.1.1", "1.0.1") == .orderedDescending)
    }

    @Test func testBuildMetadataStripping() {
        #expect(SemVerComparer.compare("1.2.0-beta.1", "1.1.9") == .orderedDescending)
        #expect(SemVerComparer.compare("v2.1.0-rc1", "v2.1.0") == .orderedSame)
    }

    /// `+build` metadata must be discarded, not folded into the version.
    /// Dropping unparsable components shifted the remainder left, so
    /// `1.0.1+build.2` parsed as `[1, 0, 2]` and compared newer than `1.0.1` —
    /// the app then offered an "update" to the version already running.
    @Test func testBuildMetadataDoesNotInflateVersion() {
        #expect(SemVerComparer.compare("1.0.1+build.2", "1.0.1") == .orderedSame)
        #expect(SemVerComparer.compare("1.0.1+build.2", "1.0.2") == .orderedAscending)
        #expect(SemVerComparer.compare("1.0.0-beta+exp.sha.5114f85", "1.0.0") == .orderedSame)
    }

    /// A component that isn't a number ends the parse rather than vanishing
    /// from the middle of it.
    @Test func testNonNumericComponentTerminatesParse() {
        // "1.x.9" truncates to [1], i.e. 1.0.0 — the trailing 9 must not slide
        // into the minor position.
        #expect(SemVerComparer.compare("1.x.9", "1.0.0") == .orderedSame)
        #expect(SemVerComparer.compare("1.x.9", "1.1.0") == .orderedAscending)
        #expect(SemVerComparer.compare("garbage", "0.0.0") == .orderedSame)
    }

    /// The ordering the release picker relies on: it takes the maximum by this
    /// comparator, so a backport published after a minor release must still
    /// sort below it.
    @Test func testBackportSortsBelowNewerMinor() {
        let versions = ["1.0.2", "1.1.0", "1.0.3"]
        let highest = versions.max { SemVerComparer.compare($0, $1) == .orderedAscending }
        #expect(highest == "1.1.0")
    }
}
