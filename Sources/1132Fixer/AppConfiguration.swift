import Foundation

enum AppConfiguration {
    static let githubOwner = "1132-Fixer"
    static let githubRepository = "macos"
    static let websiteURL = URL(string: "https://1132-fixer.xyz")!
    static let repositoryURL = URL(string: "https://github.com/\(githubOwner)/\(githubRepository)")!
    static let latestReleaseURL = repositoryURL
        .appendingPathComponent("releases")
        .appendingPathComponent("latest")
    static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/\(githubOwner)/\(githubRepository)/releases/latest"
    )!

    static var allowsDebugEnvironmentOverrides: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
