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

    @Test("redactingHomeDirectory replaces the home path with ~")
    func redactingHomeDirectory() {
        let text = """
        Zoom app path: /Users/jane/Applications/zoom.us.app
        OK Backup State: Saved to /Users/jane/Library/Application Support/1132Fixer/Backups/2026-01-01T00-00-00Z
        """
        let redacted = DiagnosticsCollector.redactingHomeDirectory(text, homeDirectory: "/Users/jane")

        #expect(!redacted.contains("jane"))
        #expect(redacted.contains("~/Applications/zoom.us.app"))
        #expect(redacted.contains("~/Library/Application Support/1132Fixer/Backups/"))
    }

    @Test("redactingHomeDirectory tolerates a trailing slash")
    func redactingHomeDirectoryTrailingSlash() {
        let redacted = DiagnosticsCollector.redactingHomeDirectory(
            "path: /Users/jane/Library/Logs",
            homeDirectory: "/Users/jane/"
        )
        #expect(redacted == "path: ~/Library/Logs")
    }

    @Test("redactingHomeDirectory leaves text alone for degenerate home paths")
    func redactingHomeDirectoryDegenerateHome() {
        // Replacing "" or "/" would corrupt every path in the report.
        let text = "path: /Users/jane/Library/Logs"
        #expect(DiagnosticsCollector.redactingHomeDirectory(text, homeDirectory: "") == text)
        #expect(DiagnosticsCollector.redactingHomeDirectory(text, homeDirectory: "/") == text)
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
