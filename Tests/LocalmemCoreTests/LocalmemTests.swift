import Testing
@testable import LocalmemCore

@Suite("Localmem constants")
struct LocalmemTests {
    @Test("preauthorizedToolNames lists the three current memory tools, sorted")
    func preauthorizedToolNamesIsTheExpectedSet() {
        #expect(Localmem.preauthorizedToolNames == [
            "memory_recent",
            "memory_search",
            "memory_store",
        ])
    }

    @Test("preauthorizedToolNames contains no duplicates or empty strings")
    func preauthorizedToolNamesIsClean() {
        let names = Localmem.preauthorizedToolNames
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }
}
