import Foundation
import Testing
@testable import _132Fixer

@Suite("BugReportService")
struct BugReportServiceTests {

    // MARK: - Endpoint validation

    @Test func acceptsHTTPSEndpoints() {
        #expect(BugReportService.validatedEndpointURL("https://example.com/api/bug-report") != nil)
        #expect(BugReportService.validatedEndpointURL("  https://example.com/api  ") != nil)
        #expect(BugReportService.validatedEndpointURL("HTTPS://example.com/api") != nil)
    }

    @Test func rejectsNonHTTPSEndpoints() {
        #expect(BugReportService.validatedEndpointURL("http://example.com/api") == nil)
        #expect(BugReportService.validatedEndpointURL("ftp://example.com/api") == nil)
        #expect(BugReportService.validatedEndpointURL("file:///etc/passwd") == nil)
        #expect(BugReportService.validatedEndpointURL("example.com/api") == nil)
        #expect(BugReportService.validatedEndpointURL("https://") == nil)
        #expect(BugReportService.validatedEndpointURL("") == nil)
    }

    @Test func rejectsEndpointsWithEmbeddedCredentials() {
        #expect(BugReportService.validatedEndpointURL("https://user:pass@example.com/api") == nil)
    }

    @Test func tokenMustBeSingleLine() {
        #expect(BugReportService.isValidToken("abc123"))
        #expect(!BugReportService.isValidToken(""))
        #expect(!BugReportService.isValidToken("abc\r\nX-Injected: 1"))
    }

    // MARK: - Attachment size

    @Test func smallAttachmentsAreUntouched() {
        let data = Data("short log".utf8)
        #expect(BugReportService.truncatedAttachment(data, limit: 1_000) == data)
    }

    @Test func oversizedAttachmentsKeepTheMostRecentPartWithinTheLimit() {
        let text = String(repeating: "old line\n", count: 500) + "NEWEST LINE\n"
        let data = Data(text.utf8)
        let result = BugReportService.truncatedAttachment(data, limit: 400)
        #expect(result.count <= 400)
        let resultText = String(decoding: result, as: UTF8.self)
        #expect(resultText.hasPrefix("[truncated"))
        #expect(resultText.hasSuffix("NEWEST LINE\n"))
    }

    @Test func truncationDoesNotSplitMultibyteCharacters() {
        let data = Data(String(repeating: "é", count: 1_000).utf8)
        let result = BugReportService.truncatedAttachment(data, limit: 301)
        #expect(String(data: result, encoding: .utf8) != nil)
        #expect(result.count <= 301)
    }

    @Test func defaultLimitIsOneMegabyte() {
        #expect(BugReportService.maxAttachmentBytes == 1_048_576)
    }

    // MARK: - Header sanitizing

    @Test func headerValuesLoseLineBreaks() {
        let value = BugReportService.escapedHeaderValue("log.txt\r\nX-Injected: yes\nmore")
        #expect(!value.contains("\r"))
        #expect(!value.contains("\n"))
        #expect(value == "log.txtX-Injected: yesmore")
    }

    @Test func headerValuesEscapeQuotesAndBackslashes() {
        #expect(BugReportService.escapedHeaderValue(#"a"b\c"#) == #"a\"b\\c"#)
    }

    // MARK: - Server response text

    @Test func serverDetailIsTruncatedToTwoHundredCharacters() {
        let data = Data(String(repeating: "x", count: 5_000).utf8)
        let detail = BugReportService.truncatedServerDetail(from: data)
        #expect(detail.count == BugReportService.maxServerDetailCharacters + 1) // 200 + ellipsis
        #expect(detail.hasSuffix("…"))
    }

    @Test func serverDetailIsFlattenedToOneLine() {
        let detail = BugReportService.truncatedServerDetail(from: Data("line one\nline two\r\n".utf8))
        #expect(!detail.contains("\n"))
        #expect(!detail.contains("\r"))
        #expect(detail.hasPrefix("line one"))
    }

    @Test func emptyServerDetailStaysEmpty() {
        #expect(BugReportService.truncatedServerDetail(from: Data()) == "")
    }
}
