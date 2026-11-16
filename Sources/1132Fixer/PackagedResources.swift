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

    /// Native mounted-artifact canary: the packaged app can find its icon resource.
    static func hasRequiredResources() -> Bool {
        resourceURL(named: "AppIcon.png") != nil
    }
}
