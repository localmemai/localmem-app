import Foundation
import Testing
@testable import localmem_mcp

@Suite("MCPClientIdentity")
struct MCPClientIdentityTests {
    @Test("name returns the constructor fallback when nothing has been captured")
    func nameUsesFallback() async {
        let identity = MCPClientIdentity(fallback: "test-client")
        let name = await identity.name
        #expect(name == "test-client")
    }

    @Test("set captures a non-empty client name and name reflects it")
    func setCapturesName() async {
        let identity = MCPClientIdentity(fallback: "fallback")
        await identity.set("claude-code")
        let name = await identity.name
        #expect(name == "claude-code")
    }

    @Test("set is a no-op for nil and empty strings — fallback remains in effect")
    func setIgnoresNilAndEmpty() async {
        let identity = MCPClientIdentity(fallback: "fallback")
        await identity.set(nil)
        await identity.set("")
        let name = await identity.name
        #expect(name == "fallback")
    }
}
