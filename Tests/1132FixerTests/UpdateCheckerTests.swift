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
            "html_url": "https://github.com/SeanPVera/1132-fixer/releases/tag/v1.2.3",
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
        #expect(releaseInfo.htmlURL.absoluteString == "https://github.com/SeanPVera/1132-fixer/releases/tag/v1.2.3")
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
            "html_url": "https://github.com/SeanPVera/1132-fixer/releases/tag/v1.2.3",
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
            "html_url": "https://github.com/SeanPVera/1132-fixer/releases/tag/v1.2.3-beta",
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
            "html_url": "https://github.com/SeanPVera/1132-fixer/releases/tag/v1.2.3"
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

    // MARK: F-046 byte, redirect and canonical-link policy

    private static func releaseJSON(tag: String = "v1.2.3", htmlURL: String? = nil, padding: Int = 0) -> Data {
        let link = htmlURL ?? "https://github.com/SeanPVera/1132-fixer/releases/tag/\(tag)"
        let body = String(repeating: "x", count: padding)
        return Data(#"{"tag_name":"\#(tag)","html_url":"\#(link)","body":"\#(body)","draft":false,"prerelease":false}"#.utf8)
    }

    @Test func oversizedResponseIsRefused() async {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Self.releaseJSON(padding: UpdateChecker.maxResponseBytes + 1))
        }
        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            Issue.record("Oversized response was accepted")
        } catch let error as NSError {
            #expect(error.domain == UpdateChecker.errorDomain)
            #expect(error.code == 3)
        }
    }

    @Test func canonicalLinkIsBuiltLocallyFromTheValidatedTag() async throws {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()
        // A trusted-looking but non-canonical html_url (different release path) is not used.
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Self.releaseJSON(tag: "v2.0.1", htmlURL: "https://github.com/SeanPVera/1132-fixer/releases/download/v2.0.1/other.dmg"))
        }
        let info = try await UpdateChecker.fetchLatestRelease(session: session)
        #expect(info.htmlURL.absoluteString == "https://github.com/SeanPVera/1132-fixer/releases/tag/v2.0.1")
    }

    @Test(arguments: ["v1.2.3/../../x", "v1.2.3?x=1", "1.2", "v1.2.3#frag", "v1.2.3 ", ""])
    func malformedTagsCannotProduceALink(tag: String) async {
        defer { MockURLProtocol.requestHandler = nil }
        let session = makeSession()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Self.releaseJSON(tag: tag, htmlURL: "https://github.com/SeanPVera/1132-fixer/releases/tag/v1.2.3"))
        }
        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            Issue.record("Malformed tag produced a release link")
        } catch let error as NSError {
            #expect(error.domain == UpdateChecker.errorDomain)
            #expect(error.code == 2)
        }
    }

    @Test func crossHostRedirectIsNeverAccepted() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        do {
            _ = try await UpdateChecker.fetchLatestRelease(session: session)
            Issue.record("A response reached through a cross-host redirect was accepted")
        } catch {
            // Either the redirect was declined (3xx is not success) or the final host check refused it.
        }
    }

    @Test func redirectPolicyAllowsOnlyHTTPSGitHubAPI() {
        #expect(UpdateChecker.RedirectPolicy.allows(URL(string: "https://api.github.com/repos/x/y/releases/latest")))
        for bad in ["https://evil.example/x", "http://api.github.com/x", "https://api.github.com.evil.example/x",
                    "https://user@api.github.com/x", "https://api.github.com:8443/x", "https://github.com/x"] {
            #expect(!UpdateChecker.RedirectPolicy.allows(URL(string: bad)), "allowed \(bad)")
        }
        #expect(!UpdateChecker.RedirectPolicy.allows(nil))
    }
}

/// Redirects the GitHub API request to another host, which serves a valid-looking release.
final class RedirectingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.host == UpdateChecker.apiHost {
            let target = URL(string: "https://evil.example/latest")!
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = Data(#"{"tag_name":"v99.0.0","html_url":"https://github.com/SeanPVera/1132-fixer/releases/tag/v99.0.0","draft":false,"prerelease":false}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - Release URL validation (swift-testing)

@Suite("UpdateChecker release URL")
struct UpdateCheckerURLTests {

    @Test func acceptsGitHubReleaseURLs() {
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/SeanPVera/1132-fixer/releases/tag/v1.8.1")!))
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://GitHub.com/SeanPVera/1132-fixer/releases/latest")!))
        #expect(UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com:443/SeanPVera/1132-fixer/releases/tag/v1")!))
    }

    @Test func rejectsReleaseURLsForOtherRepositories() {
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/attacker/project/releases/tag/v1")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/SeanPVera/1132-fixer-malware/releases/tag/v1")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/SeanPVera/1132-fixer")!))
        #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/SeanPVera/1132-fixer/releases/../../attacker/project")!))
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
