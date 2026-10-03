import Foundation
import Testing
import XCTest
@testable import _132Fixer

class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler is unavailable.")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op
    }
}

final class UpdateCheckerTests: XCTestCase {

    var session: URLSession!

    override func setUp() {
        super.setUp()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session = nil
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchLatestRelease_Success() async throws {
        let jsonString = """
        {
            "tag_name": "v1.2.3",
            "html_url": "https://github.com/PrimeUpYourLife/1132-fixer/releases/tag/v1.2.3",
            "body": "Test release notes",
            "draft": false,
            "prerelease": false
        }
        """
        let data = jsonString.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let releaseInfo = try await UpdateChecker.fetchLatestRelease(session: session)

        XCTAssertEqual(releaseInfo.version, "1.2.3")
        XCTAssertEqual(releaseInfo.htmlURL.absoluteString, "https://github.com/PrimeUpYourLife/1132-fixer/releases/tag/v1.2.3")
        XCTAssertEqual(releaseInfo.releaseNotes, "Test release notes")
    }

    func testFetchLatestRelease_HTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            XCTFail("Expected fetchLatestRelease to throw an error")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, UpdateChecker.errorDomain)
            XCTAssertEqual(error.code, 404)
        }
    }

    func testFetchLatestRelease_DraftRelease() async {
        let jsonString = """
        {
            "tag_name": "v1.2.3",
            "html_url": "https://github.com/PrimeUpYourLife/1132-fixer/releases/tag/v1.2.3",
            "body": "Draft release notes",
            "draft": true,
            "prerelease": false
        }
        """
        let data = jsonString.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            XCTFail("Expected fetchLatestRelease to throw an error for draft release")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, UpdateChecker.errorDomain)
            XCTAssertEqual(error.code, 1)
        }
    }

    func testFetchLatestRelease_PreRelease() async {
        let jsonString = """
        {
            "tag_name": "v1.2.3-beta",
            "html_url": "https://github.com/PrimeUpYourLife/1132-fixer/releases/tag/v1.2.3-beta",
            "body": "Pre-release notes",
            "draft": false,
            "prerelease": true
        }
        """
        let data = jsonString.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            XCTFail("Expected fetchLatestRelease to throw an error for pre-release")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, UpdateChecker.errorDomain)
            XCTAssertEqual(error.code, 1)
        }
    }

    func testFetchLatestRelease_InvalidURL() async {
        let jsonString = """
        {
            "tag_name": "v1.2.3",
            "html_url": "http://example.com",
            "body": "Release notes",
            "draft": false,
            "prerelease": false
        }
        """
        let data = jsonString.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            XCTFail("Expected fetchLatestRelease to throw an error for invalid URL")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, UpdateChecker.errorDomain)
            XCTAssertEqual(error.code, 2)
        }
    }

    func testFetchLatestRelease_LookalikeHostRejected() async {
        let jsonString = """
        {
            "tag_name": "v9.9.9",
            "html_url": "https://github.com.attacker.example/releases/tag/v9.9.9",
            "body": "Release notes",
            "draft": false,
            "prerelease": false
        }
        """
        let data = jsonString.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            XCTFail("Expected fetchLatestRelease to reject a github.com lookalike host")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, UpdateChecker.errorDomain)
            XCTAssertEqual(error.code, 2)
        }
    }

    func testFetchLatestRelease_InvalidJSON() async {
        let jsonString = """
        {
            "tag_name": "v1.2.3",
            "html_url": "https://github.com/PrimeUpYourLife/1132-fixer/releases/tag/v1.2.3"
        """ // Missing closing brace and other fields
        let data = jsonString.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            XCTFail("Expected fetchLatestRelease to throw a decoding error")
        } catch {
            // Decoding error is expected
            XCTAssertTrue(error is DecodingError)
        }
    }
}

// MARK: - Release URL validation (swift-testing)

@Suite("UpdateChecker release URL")
struct UpdateCheckerURLTests {

    @Test func acceptsGitHubReleaseURLs() {
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/1132-Fixer/macos/releases/tag/v1.7.7")!))
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://GitHub.com/1132-Fixer/macos")!))
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com:443/1132-Fixer/macos")!))
    }

    @Test func rejectsLookalikeHosts() {
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://evilgithub.com/x")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com.evil.example/x")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://notgithub.com/x")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://www.github.com/x")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com@evil.example/x")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://user@github.com/x")!))
    }

    @Test func rejectsNonHTTPSAndOddPorts() {
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "http://github.com/x")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "ftp://github.com/x")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "file:///etc/hosts")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com:8443/x")!))
    }
}
