import Foundation

enum BugReportService {
    private static let errorDomain = "1132Fixer.BugReportService"
    private static let userAgent = "1132Fixer-BugReportClient"
    private static let endpointEnvVar = "FIXER_BUG_REPORT_ENDPOINT"
    // SECURITY: a token that ships inside an app bundle (or is read from its environment)
    // can be extracted by anyone who has the app. Treat it as a low-trust, write-only key
    // that only identifies "a copy of this app": the server must rate-limit it, accept
    // submissions only, and never grant it read access or any other privilege.
    private static let tokenEnvVar = "FIXER_BUG_REPORT_TOKEN"
    private static let defaultEndpoint = "https://1132-bug-report-production.up.railway.app/api/bug-report"
    private static let uploadFieldName = "file"

    /// Largest diagnostics attachment that is uploaded; longer logs are cut to their most recent part.
    static let maxAttachmentBytes = 1_048_576
    /// Longest slice of a server response that is ever shown in the UI.
    static let maxServerDetailCharacters = 200

    /// The endpoint environment variable redirects where the bearer token is sent, so it is
    /// honored in debug builds only. Release builds use the bundled endpoint or the default.
    static var allowsEndpointEnvironmentOverride: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func resolveConfigValue(envVar: String, allowEnvironmentOverride: Bool = true, fallback: String = "") -> String {
        let envValue = allowEnvironmentOverride
            ? (ProcessInfo.processInfo.environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""
        if !envValue.isEmpty {
            return envValue
        }

        // Avoid Bundle.module: the SPM-generated accessor calls Swift.fatalError() when the
        // resource bundle is not found at the expected path, crashing the app for packaged builds
        // where Bundle.main.bundleURL does not point to Contents/Resources/.
        let resourceBundleName = "1132 Fixer_1132Fixer.bundle"
        var bundlesToSearch: [Bundle] = []

        // CLI / debug builds: the resource bundle sits beside the executable.
        if let execURL = Bundle.main.executableURL {
            let siblingURL = execURL.deletingLastPathComponent().appendingPathComponent(resourceBundleName)
            if let b = Bundle(url: siblingURL) { bundlesToSearch.append(b) }
        }

        // Packaged .app builds: the resource bundle is in Contents/Resources/.
        if let url = Bundle.main.url(forResource: "1132 Fixer_1132Fixer", withExtension: "bundle"),
           let b = Bundle(url: url) {
            bundlesToSearch.append(b)
        }

        bundlesToSearch.append(Bundle.main)

        for bundle in bundlesToSearch {
            guard let resourceURL = bundle.url(forResource: envVar, withExtension: nil),
                  let data = try? Data(contentsOf: resourceURL),
                  let bundledValue = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundledValue.isEmpty else {
                continue
            }
            return bundledValue
        }

        return fallback
    }

    static func sendBugReport(
        title: String,
        email: String?,
        message: String,
        systemInfo: String,
        diagnosticsFileName: String,
        diagnosticsData: Data
    ) async throws {
        let endpoint = resolveConfigValue(
            envVar: endpointEnvVar,
            allowEnvironmentOverride: allowsEndpointEnvironmentOverride,
            fallback: defaultEndpoint
        )
        let token = resolveConfigValue(envVar: tokenEnvVar)

        guard !token.isEmpty else {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bug report token in env/resource \(tokenEnvVar)."]
            )
        }

        guard isValidToken(token) else {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The bug report token is not valid."]
            )
        }

        // The bearer token is only ever sent over HTTPS.
        guard let url = validatedEndpointURL(endpoint) else {
            throw NSError(
                domain: errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid bug report endpoint URL. It must be an https:// URL."]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            title: title,
            email: email,
            message: message,
            systemInfo: systemInfo,
            diagnosticsFileName: diagnosticsFileName,
            diagnosticsData: truncatedAttachment(diagnosticsData)
        )

        // Do not follow redirects: they could carry the bearer token to another (or non-HTTPS) host.
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: errorDomain,
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Bug report API returned an invalid response."]
            )
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = truncatedServerDetail(from: data)
            let contextMessage: String
            if http.statusCode == 404, detail.contains("Application not found") {
                contextMessage = "The bug report service is currently unavailable (HTTP 404). Please try again later."
            } else if detail.isEmpty {
                contextMessage = "Bug report submission failed (HTTP \(http.statusCode))."
            } else {
                contextMessage = "Bug report submission failed (HTTP \(http.statusCode)). Server said: \(detail)"
            }
            throw NSError(
                domain: errorDomain,
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: contextMessage]
            )
        }
    }

    // MARK: - Validation and sanitizing helpers

    /// Returns the URL only if it is an `https` URL with a host and no embedded credentials.
    static func validatedEndpointURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            return nil
        }
        return url
    }

    /// A token must be non-empty and free of control characters (which could split the header).
    static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Keeps the most recent part of an oversized attachment (the end of a log is the most
    /// useful), prefixed with a note, so the result never exceeds `limit` bytes.
    static func truncatedAttachment(_ data: Data, limit: Int = BugReportService.maxAttachmentBytes) -> Data {
        guard data.count > limit else { return data }

        let note = Data("[truncated: showing the last part of \(data.count) bytes]\n".utf8)
        let keep = max(limit - note.count, 0)
        var tail = data.suffix(keep)
        // Do not start in the middle of a multi-byte UTF-8 character.
        while let first = tail.first, first & 0xC0 == 0x80 {
            tail = tail.dropFirst()
        }
        return note + tail
    }

    /// At most `maxServerDetailCharacters` characters of a server response, on one line, so a
    /// misbehaving server cannot flood the UI or the log.
    static func truncatedServerDetail(from data: Data) -> String {
        let text = String(decoding: data.prefix(maxServerDetailCharacters * 4), as: UTF8.self)
        let flattened = text
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > maxServerDetailCharacters else { return flattened }
        return String(flattened.prefix(maxServerDetailCharacters)) + "…"
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static func makeMultipartBody(
        boundary: String,
        title: String,
        email: String?,
        message: String,
        systemInfo: String,
        diagnosticsFileName: String,
        diagnosticsData: Data
    ) -> Data {
        var body = Data()

        func appendTextField(_ name: String, value: String) {
            body.append("--\(boundary)\r\n".utf8Data)
            body.append("Content-Disposition: form-data; name=\"\(escapedHeaderValue(name))\"\r\n\r\n".utf8Data)
            body.append(value.utf8Data)
            body.append("\r\n".utf8Data)
        }

        appendTextField("Title", value: title)
        if let email, !email.isEmpty {
            appendTextField("Email", value: email)
        }
        appendTextField("Message", value: message)
        appendTextField("System Info", value: systemInfo)

        body.append("--\(boundary)\r\n".utf8Data)
        body.append(
            "Content-Disposition: form-data; name=\"\(escapedHeaderValue(uploadFieldName))\"; filename=\"\(escapedHeaderValue(diagnosticsFileName))\"\r\n".utf8Data
        )
        body.append("Content-Type: text/plain\r\n\r\n".utf8Data)
        body.append(diagnosticsData)
        body.append("\r\n".utf8Data)
        body.append("--\(boundary)--\r\n".utf8Data)

        return body
    }

    /// Makes a value safe for a quoted `Content-Disposition` parameter: CR, LF and other control
    /// characters are dropped (they would let a value start a new header), then backslashes
    /// and quotes are escaped.
    static func escapedHeaderValue(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
