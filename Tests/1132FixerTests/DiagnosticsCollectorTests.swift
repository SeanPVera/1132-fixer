import Testing
import Foundation
@testable import _132Fixer

@Suite("DiagnosticsCollector")
struct DiagnosticsCollectorTests {

    @Test("yesNo formats correctly")
    func yesNo() {
        #expect(DiagnosticsCollector.yesNo(true) == "yes")
        #expect(DiagnosticsCollector.yesNo(false) == "no")
    }

    @Test("formatBytes formats correctly")
    func formatBytes() {
        // Test formatting for bytes, MB and GB using typical sizes.
        // The exact output might depend slightly on the OS version for '0' (e.g., "Zero KB"),
        // but 1 MB and 1 GB are standard.
        let oneMB: UInt64 = 1024 * 1024
        let oneGB: UInt64 = 1024 * 1024 * 1024

        let mbString = DiagnosticsCollector.formatBytes(oneMB)
        #expect(mbString.contains("MB"))

        let gbString = DiagnosticsCollector.formatBytes(oneGB)
        #expect(gbString.contains("GB"))
    }

    @Test("formatDuration formats correctly")
    func formatDuration() {
        #expect(DiagnosticsCollector.formatDuration(0) == "0h 0m")
        #expect(DiagnosticsCollector.formatDuration(59) == "0h 0m")
        #expect(DiagnosticsCollector.formatDuration(60) == "0h 1m")
        #expect(DiagnosticsCollector.formatDuration(3599) == "0h 59m")
        #expect(DiagnosticsCollector.formatDuration(3600) == "1h 0m")
        #expect(DiagnosticsCollector.formatDuration(3660) == "1h 1m")
        #expect(DiagnosticsCollector.formatDuration(90000) == "25h 0m")
    }
}
