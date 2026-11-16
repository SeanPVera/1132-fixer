import Foundation

struct ReleaseInfo: Equatable {
    let version: String
    let htmlURL: URL
    let releaseNotes: String?
}

enum UpdateChecker {
    static let owner = AppConfiguration.githubOwner
    static let repo = AppConfiguration.githubRepository
    static let errorDomain = "1132Fixer.UpdateChecker"
    private static let userAgent = "1132Fixer"

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case draft
            case prerelease
        }
    }

    /// The only host the unauthenticated update request may talk to, including after redirects.
    static let apiHost = "api.github.com"
    /// Largest response body that is read. A GitHub "latest release" document is a few KB;
    /// anything larger is refused rather than buffered (F-046).
    static let maxResponseBytes = 256 * 1_024

    /// Allows a redirect only to HTTPS on `api.github.com`; any other redirect is not
    /// followed, so the redirect response itself becomes the (rejected) final response.
    final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        static func allows(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.scheme?.lowercased() == "https"
                && url.host?.lowercased() == UpdateChecker.apiHost
                && url.user == nil && url.password == nil
                && (url.port == nil || url.port == 443)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(Self.allows(request.url) ? request : nil)
        }
    }

    static func fetchLatestRelease(session: URLSession = .shared) async throws -> ReleaseInfo {
        var request = URLRequest(url: AppConfiguration.latestReleaseAPIURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectPolicy())
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            bytes.task.cancel()
            throw NSError(
                domain: errorDomain,
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub API returned HTTP \(http.statusCode)."]
            )
        }
        guard RedirectPolicy.allows(response.url ?? request.url) else {
            bytes.task.cancel()
            throw NSError(
                domain: errorDomain,
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The update response did not come from \(apiHost)."]
            )
        }
        let data = try await readBounded(bytes, expectedLength: response.expectedContentLength)

        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // `/releases/latest` should already exclude drafts/prereleases, but keep a guardrail.
        if decoded.draft == true || decoded.prerelease == true {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Latest release is not a stable release."]
            )
        }

        let version = normalizeVersion(decoded.tagName)
        guard let reportedURL = URL(string: decoded.htmlURL),
              isTrustedReleaseURL(reportedURL),
              let canonicalURL = canonicalReleaseURL(forTag: decoded.tagName) else {
            throw NSError(
                domain: errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid release URL."]
            )
        }

        // The link that is opened is built locally from the validated tag; the API's
        // `html_url` is only checked, never used.
        return ReleaseInfo(version: version, htmlURL: canonicalURL, releaseNotes: decoded.body)
    }

    private static func readBounded(_ bytes: URLSession.AsyncBytes, expectedLength: Int64) async throws -> Data {
        let tooLarge = NSError(
            domain: errorDomain,
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "The update response was larger than \(maxResponseBytes) bytes."]
        )
        if expectedLength > Int64(maxResponseBytes) {
            bytes.task.cancel()
            throw tooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maxResponseBytes, max(0, Int(clamping: expectedLength))))
        for try await byte in bytes {
            if data.count >= maxResponseBytes {
                bytes.task.cancel()
                throw tooLarge
            }
            data.append(byte)
        }
        return data
    }

    /// A release tag this app will link to: `v` optional, three numeric parts, and an
    /// optional `-suffix` of letters, digits, dots and hyphens.
    static func isValidReleaseTag(_ tag: String) -> Bool {
        tag.count <= 64
            && tag.range(of: #"^[vV]?[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-[0-9A-Za-z.-]{1,40})?$"#, options: .regularExpression) != nil
    }

    /// The canonical GitHub release page for a validated tag, constructed locally.
    static func canonicalReleaseURL(forTag tag: String) -> URL? {
        guard isValidReleaseTag(tag) else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)")
    }

    /// Release links are opened in the browser, so accept only this app's canonical
    /// GitHub Releases path.
    /// The host must match exactly: a substring check would also accept hosts such as
    /// `evilgithub.com` or `github.com.evil.example`.
    static func isTrustedReleaseURL(_ url: URL) -> Bool {
        let expectedPathPrefix = "/\(owner)/\(repo)/releases/".lowercased()
        let normalizedPath = url.standardized.path.lowercased()
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              normalizedPath.hasPrefix(expectedPathPrefix) else {
            return false
        }
        return true
    }

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        return s
    }

    static func isUpdateAvailable(currentVersion: String, latestVersion: String) -> Bool {
        guard let current = SemVer.parse(currentVersion),
              let latest = SemVer.parse(latestVersion) else {
            return false
        }
        return latest > current
    }
}

struct SemVer: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func parse(_ s: String) -> SemVer? {
        // Accept "1.2.3" and tolerate suffixes like "1.2.3-beta" by stripping at first non [0-9.].
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.prefix { ch in
            (ch >= "0" && ch <= "9") || ch == "."
        }
        let parts = allowed.split(separator: ".")
        guard parts.count >= 1 else { return nil }

        func intPart(_ idx: Int) -> Int? {
            guard idx < parts.count else { return 0 }
            return Int(parts[idx])
        }

        guard let major = intPart(0),
              let minor = intPart(1),
              let patch = intPart(2) else {
            return nil
        }

        return SemVer(major: major, minor: minor, patch: patch)
    }
}
