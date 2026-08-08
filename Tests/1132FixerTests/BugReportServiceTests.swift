import Testing
@testable import _1132Fixer

@Suite("BugReportService")
struct BugReportServiceTests {

    @Test("escapedHeaderValue handles standard string")
    func escapedHeaderValue_standardString() {
        let input = "filename.txt"
        let expected = "filename.txt"
        let result = BugReportService.escapedHeaderValue(input)
        #expect(result == expected)
    }

    @Test("escapedHeaderValue escapes double quotes")
    func escapedHeaderValue_doubleQuotes() {
        let input = "file\"name.txt"
        let expected = "file\\\"name.txt"
        let result = BugReportService.escapedHeaderValue(input)
        #expect(result == expected)
    }

    @Test("escapedHeaderValue escapes backslashes")
    func escapedHeaderValue_backslashes() {
        let input = "file\\name.txt"
        let expected = "file\\\\name.txt"
        let result = BugReportService.escapedHeaderValue(input)
        #expect(result == expected)
    }

    @Test("escapedHeaderValue escapes both quotes and backslashes")
    func escapedHeaderValue_combined() {
        let input = "file\\name\"with\"quotes.txt"
        let expected = "file\\\\name\\\"with\\\"quotes.txt"
        let result = BugReportService.escapedHeaderValue(input)
        #expect(result == expected)
    }

    @Test("escapedHeaderValue handles string with only quotes and backslashes")
    func escapedHeaderValue_onlySpecialChars() {
        let input = "\\\"\\\""
        let expected = "\\\\\\\"\\\\\\\""
        let result = BugReportService.escapedHeaderValue(input)
        #expect(result == expected)
    }
}
