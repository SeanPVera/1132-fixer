import Foundation

enum BugReportService {
    private static let errorDomain = "1132Fixer.BugReportService"
    private static let userAgent = "1132Fixer-BugReportClient"
    private static let endpointEnvVar = "FIXER_BUG_REPORT_ENDPOINT"
    private static let tokenEnvVar = "FIXER_BUG_REPORT_TOKEN"
    private static let defaultEndpoint = "https://1132-bug-report-production.up.railway.app/api/bug-report"
    private static let uploadFieldName = "file"

    private static func resolveConfigValue(envVar: String, fallback: String = "") async -> String {
        let envValue = ProcessInfo.processInfo.environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            guard let resourceURL = bundle.url(forResource: envVar, withExtension: nil) else { continue }

            // Offload synchronous I/O to avoid blocking the Swift concurrency thread pool
            let data = await Task.detached {
                try? Data(contentsOf: resourceURL)
            }.value

            guard let data,
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
        let endpoint = await resolveConfigValue(envVar: endpointEnvVar, fallback: defaultEndpoint)
        let token = await resolveConfigValue(envVar: tokenEnvVar)

        guard !token.isEmpty else {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bug report token in env/resource \(tokenEnvVar)."]
            )
        }

        guard let url = URL(string: endpoint) else {
            throw NSError(
                domain: errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid bug report endpoint URL."]
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
            diagnosticsData: diagnosticsData
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: errorDomain,
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Bug report API returned an invalid response."]
            )
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (detail?.isEmpty == false) ? detail! : "HTTP \(http.statusCode)"
            let endpointHint = "Check \(endpointEnvVar) value."
            let contextMessage: String
            if http.statusCode == 404, message.contains("Application not found") {
                contextMessage = "Bug report endpoint is unreachable on Railway. \(endpointHint) Response: \(message)"
            } else {
                contextMessage = "Bug report submission failed (\(endpoint)). \(endpointHint) Response: \(message)"
            }
            throw NSError(
                domain: errorDomain,
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: contextMessage]
            )
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
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8Data)
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
            "Content-Disposition: form-data; name=\"\(uploadFieldName)\"; filename=\"\(escapedHeaderValue(diagnosticsFileName))\"\r\n".utf8Data
        )
        body.append("Content-Type: text/plain\r\n\r\n".utf8Data)
        body.append(diagnosticsData)
        body.append("\r\n".utf8Data)
        body.append("--\(boundary)--\r\n".utf8Data)

        return body
    }

    static func escapedHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
