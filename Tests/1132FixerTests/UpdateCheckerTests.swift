import Foundation
import Testing
@testable import _132Fixer

@Suite("UpdateChecker")
struct UpdateCheckerTests {

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
