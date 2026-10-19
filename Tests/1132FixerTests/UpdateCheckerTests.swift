import Foundation
import Testing
@testable import _132Fixer

final class MockURLProtocol: URLProtocol {
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

@Suite("UpdateChecker network fetch", .serialized)
struct UpdateCheckerTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func fetchLatestReleaseSuccess() async throws {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()

        let jsonString = """
        {
            "tag_name": "v1.2.3",
            "html_url": "https://github.com/1132-Fixer/macos/releases/tag/v1.2.3",
            "body": "Test release notes",
            "draft": false,
            "prerelease": false
        }
        """
        let data = jsonString.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            #expect(request.url == AppConfiguration.latestReleaseAPIURL)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let releaseInfo = try await UpdateChecker.fetchLatestRelease(session: session)

        #expect(releaseInfo.version == "1.2.3")
        #expect(releaseInfo.htmlURL.absoluteString == "https://github.com/1132-Fixer/macos/releases/tag/v1.2.3")
        #expect(releaseInfo.releaseNotes == "Test release notes")
    }

    @Test func fetchLatestReleaseHTTPError() async {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            Issue.record("Expected fetchLatestRelease to throw an error")
        } catch let error as NSError {
            #expect(error.domain == UpdateChecker.errorDomain)
            #expect(error.code == 404)
        }
    }

    @Test func fetchLatestReleaseDraftRelease() async {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()

        let jsonString = """
        {
            "tag_name": "v1.2.3",
            "html_url": "https://github.com/1132-Fixer/macos/releases/tag/v1.2.3",
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
            Issue.record("Expected fetchLatestRelease to throw an error for draft release")
        } catch let error as NSError {
            #expect(error.domain == UpdateChecker.errorDomain)
            #expect(error.code == 1)
        }
    }

    @Test func fetchLatestReleasePreRelease() async {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()

        let jsonString = """
        {
            "tag_name": "v1.2.3-beta",
            "html_url": "https://github.com/1132-Fixer/macos/releases/tag/v1.2.3-beta",
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
            Issue.record("Expected fetchLatestRelease to throw an error for pre-release")
        } catch let error as NSError {
            #expect(error.domain == UpdateChecker.errorDomain)
            #expect(error.code == 1)
        }
    }

    @Test func fetchLatestReleaseInvalidURL() async {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()

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
            Issue.record("Expected fetchLatestRelease to throw an error for invalid URL")
        } catch let error as NSError {
            #expect(error.domain == UpdateChecker.errorDomain)
            #expect(error.code == 2)
        }
    }

    @Test func fetchLatestReleaseLookalikeHostRejected() async {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()

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
            Issue.record("Expected fetchLatestRelease to reject a github.com lookalike host")
        } catch let error as NSError {
            #expect(error.domain == UpdateChecker.errorDomain)
            #expect(error.code == 2)
        }
    }

    @Test func fetchLatestReleaseInvalidJSON() async {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()

        let jsonString = """
        {
            "tag_name": "v1.2.3",
            "html_url": "https://github.com/1132-Fixer/macos/releases/tag/v1.2.3"
        """ // Missing closing brace and other fields
        let data = jsonString.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            Issue.record("Expected fetchLatestRelease to throw a decoding error")
        } catch {
            #expect(error is DecodingError)
        }
    }
}

// MARK: - Release URL validation (swift-testing)

@Suite("UpdateChecker release URL")
struct UpdateCheckerURLTests {

    @Test func acceptsGitHubReleaseURLs() {
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/1132-Fixer/macos/releases/tag/v1.8.1")!))
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://GitHub.com/1132-Fixer/macos/releases/latest")!))
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com:443/1132-Fixer/macos/releases/tag/v1")!))
    }

    @Test func rejectsReleaseURLsForOtherRepositories() {
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/attacker/project/releases/tag/v1")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/1132-Fixer/macos-malware/releases/tag/v1")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/1132-Fixer/macos")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/1132-Fixer/macos/releases/../../attacker/project")!))
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
