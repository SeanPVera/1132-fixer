import Foundation

enum AppConfiguration {
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 } ?? "dev"
    }

    static let githubOwner = "SeanPVera"
    static let githubRepository = "1132-fixer"
    static let websiteURL = URL(string: "https://1132-fixer.xyz")!
    static let repositoryURL = URL(string: "https://github.com/\(githubOwner)/\(githubRepository)")!

    static var allowsDebugEnvironmentOverrides: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
