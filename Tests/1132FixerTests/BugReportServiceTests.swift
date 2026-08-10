import Testing
@testable import _132Fixer

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

    @Test("escapedHeaderValue strips CR and LF so headers cannot be injected")
    func escapedHeaderValue_stripsNewlines() {
        let input = "file\r\nContent-Disposition: form-data; name=\"injected\"\r\n\r\nevil.txt"
        let result = BugReportService.escapedHeaderValue(input)
        #expect(!result.contains("\r"))
        #expect(!result.contains("\n"))
        #expect(result == "fileContent-Disposition: form-data; name=\\\"injected\\\"evil.txt")
    }

    @Test("escapedHeaderValue handles string with only quotes and backslashes")
    func escapedHeaderValue_onlySpecialChars() {
        let input = "\\\"\\\""
        let expected = "\\\\\\\"\\\\\\\""
        let result = BugReportService.escapedHeaderValue(input)
        #expect(result == expected)
    }
}
