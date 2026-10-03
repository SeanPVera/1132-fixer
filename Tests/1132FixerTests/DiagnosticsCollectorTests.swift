import Testing
@testable import _132Fixer

@Suite("DiagnosticsCollector")
struct DiagnosticsCollectorTests {

    @Test func runReturnsTrimmedOutput() {
        #expect(DiagnosticsCollector.run("/bin/echo", ["hello"]) == "hello")
    }

    @Test func runReturnsNilOnFailureOrMissingTool() {
        #expect(DiagnosticsCollector.run("/usr/bin/false", []) == nil)
        #expect(DiagnosticsCollector.run("/nonexistent/tool", []) == nil)
    }

    @Test func runHandlesOutputLargerThanThePipeBuffer() {
        // ~600 KB of output; waiting for exit before reading would deadlock here.
        let output = DiagnosticsCollector.run("/usr/bin/seq", ["1", "100000"])
        #expect(output?.hasSuffix("100000") == true)
        #expect((output?.count ?? 0) > 65_536)
    }
}
