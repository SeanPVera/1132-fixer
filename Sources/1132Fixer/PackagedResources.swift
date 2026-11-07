import Foundation

enum PackagedResources {
    static let bundleName = "1132 Fixer_1132Fixer.bundle"

    static func resourceURL(
        named name: String,
        executableURL: URL? = Bundle.main.executableURL,
        mainResourceURL: URL? = Bundle.main.resourceURL
    ) -> URL? {
        let roots = [
            executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
            mainResourceURL?.appendingPathComponent(bundleName),
        ].compactMap { $0 }
        for root in roots {
            for directory in [root, root.appendingPathComponent("Contents/Resources")] {
                let candidate = directory.appendingPathComponent(name)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                   attributes[.type] as? FileAttributeType == .typeRegular {
                    return candidate
                }
            }
        }
        return nil
    }

    static func configurationValue(named name: String) -> String? {
        guard let url = resourceURL(named: name),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 16_384,
              let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasUsableBugReportConfiguration() -> Bool {
        guard let endpoint = configurationValue(named: "FIXER_BUG_REPORT_ENDPOINT"),
              BugReportService.validatedEndpointURL(endpoint) != nil,
              let token = configurationValue(named: "FIXER_BUG_REPORT_TOKEN"),
              BugReportService.isValidToken(token), resourceURL(named: "AppIcon.png") != nil else { return false }
        return true
    }
}
